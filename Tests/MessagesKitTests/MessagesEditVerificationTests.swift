import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditVerificationTests {
    private typealias Snapshot = MessagesEditTargetResolver.Snapshot
    private func snapshot(text: String, revisions: [String]?, chatID: Int64 = 3,
                          guid: String = "synthetic-edit", edited: Int64 = 0,
                          markedEdited: Bool = true, fullText: String? = nil,
                          parts: [NativeMessageParts.NativePart]? = nil,
                          originals: [String: [String: Int]]? = nil) throws -> Snapshot {
        var fields: [String: Any] = [:]
        if let revisions {
            fields["ec"] = ["0": revisions.map { ["d": 2, "t": NSArchiver.archivedData(withRootObject: NSAttributedString(string: $0))] as [String: Any] }]
            if markedEdited { fields["ep"] = [0] }
            fields["otr"] = originals ?? ["0": ["lo": 0, "le": revisions.first?.utf16.count ?? 0]]
        }
        let bytes = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        var budget = NativeEditContextDecoder.Budget()
        let summary = try NativeEditContextDecoder.decode(bytes, budget: &budget, requireExactHistoryText: true)
        return Snapshot(chatRowid: chatID, chatGUID: "synthetic-chat", messageRowid: 60, messageGUID: guid,
            sentDateRaw: 1, chatStyle: 45, partIndex: 0, partText: text, fullText: fullText ?? text,
            nativeParts: parts ?? [.init(index: 0, utf16Ranges: [.init(location: 0, length: text.utf16.count)], attachmentGUID: nil)],
            participantHandles: ["person@example.com"], editContext: .init(
                date_edited: NativeMessageStatusDecoder.timestamp(raw: edited),
                date_retracted: NativeMessageStatusDecoder.timestamp(raw: 0), summary_info: summary))
    }

    @Test func acceptsMatchingContentAndOneHistoryRevision() throws {
        let before = try snapshot(text: "old", revisions: nil)
        let after = try snapshot(text: "new body", revisions: ["old", "new body"], edited: 2)
        #expect(MessagesEditVerification.matches(before: before, after: after, replacement: "new body"))
    }

    @Test func contentHistoryAndIdentityAreAllRequired() throws {
        let before = try snapshot(text: "old", revisions: nil)
        let candidates = try [
            snapshot(text: "new", revisions: nil, edited: 2),
            snapshot(text: "old", revisions: ["old", "new"], edited: 2),
            snapshot(text: "new", revisions: ["old", "new"], chatID: 4, edited: 2),
            snapshot(text: "new", revisions: ["old", "new"], guid: "other", edited: 2),
            snapshot(text: "new", revisions: ["old", "new"], edited: 0),
            snapshot(text: "new", revisions: ["old", "new"], edited: 3),
            snapshot(text: "new", revisions: ["old", "new"], edited: 2, markedEdited: false)
        ]
        for after in candidates {
            #expect(!MessagesEditVerification.matches(before: before, after: after, replacement: "new"))
        }
    }

    @Test func UnicodeEquivalentReplacementIsNotByteExact() throws {
        #expect(!MessagesEditVerification.matches(before: try snapshot(text: "old", revisions: nil),
            after: try snapshot(text: "\u{e9}", revisions: ["old", "\u{e9}"], edited: 2), replacement: "e\u{301}"))
    }

    @Test func preservesOtherPartsAndRequiresTheirExactRangeShift() throws {
        let beforeParts: [NativeMessageParts.NativePart] = [
            .init(index: 0, utf16Ranges: [.init(location: 0, length: 3)], attachmentGUID: nil),
            .init(index: 1, utf16Ranges: [.init(location: 3, length: 5)], attachmentGUID: nil)
        ]
        let afterParts: [NativeMessageParts.NativePart] = [
            .init(index: 0, utf16Ranges: [.init(location: 0, length: 8)], attachmentGUID: nil),
            .init(index: 1, utf16Ranges: [.init(location: 8, length: 5)], attachmentGUID: nil)
        ]
        let before = try snapshot(text: "old", revisions: nil, fullText: "old tail", parts: beforeParts)
        let after = try snapshot(text: "new body", revisions: ["old", "new body"], edited: 2,
            fullText: "new body tail", parts: afterParts)
        #expect(MessagesEditVerification.matches(before: before, after: after, replacement: "new body"))
        let wrongBody = try snapshot(text: "new body", revisions: ["old", "new body"], edited: 2,
            fullText: "new body fail", parts: afterParts)
        #expect(!MessagesEditVerification.matches(before: before, after: wrongBody, replacement: "new body"))
        let wrongRanges = try snapshot(text: "new body", revisions: ["old", "new body"], edited: 2,
            fullText: "new body tail", parts: beforeParts)
        #expect(!MessagesEditVerification.matches(before: before, after: wrongRanges, replacement: "new body"))
    }

    @Test func originalCoordinatesMustBePresentAndMatchFirstRevision() throws {
        let before = try snapshot(text: "old", revisions: nil)
        for originals in [[:], ["0": ["lo": 1, "le": 3]], ["0": ["lo": 0, "le": 4]],
                          ["00": ["lo": 0, "le": 3]],
                          ["0": ["lo": 0, "le": 3], "1": ["lo": 3, "le": 1]]] {
            let after = try snapshot(text: "new", revisions: ["old", "new"], edited: 2, originals: originals)
            #expect(!MessagesEditVerification.matches(before: before, after: after, replacement: "new"))
        }
    }

    @Test func repeatEditRetainsOriginalCoordinates() throws {
        let before = try snapshot(text: "old", revisions: ["initial", "old"], edited: 2)
        let after = try snapshot(text: "new", revisions: ["initial", "old", "new"], edited: 2)
        #expect(MessagesEditVerification.matches(before: before, after: after, replacement: "new"))
        let changed = try snapshot(text: "new", revisions: ["initial", "old", "new"], edited: 2,
            originals: ["0": ["lo": 0, "le": 3]])
        #expect(!MessagesEditVerification.matches(before: before, after: changed, replacement: "new"))
    }

}
