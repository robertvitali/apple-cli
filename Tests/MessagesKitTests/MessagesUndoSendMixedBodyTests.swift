import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendMixedBodyTests {
    private typealias Run = (location: Int, length: Int, index: Int, guid: String?)

    private func fixture(text: String, body: String, runs: [Run], members: [Int] = [10]) throws -> ChatFixture {
        let fx = try ChatFixture()
        let archive = NSMutableAttributedString(string: body)
        for run in runs {
            let range = NSRange(location: run.location, length: run.length)
            archive.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"),
                                 value: NSNumber(value: run.index), range: range)
            if let guid = run.guid {
                archive.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"),
                                     value: guid, range: range)
            }
        }
        try fx.insertMessage(rowid: 60, guid: "synthetic-mixed-undo", text: text,
            attributedBody: NSArchiver.archivedData(withRootObject: archive), chatRowid: 3,
            date: 800_000_000_000_000_000, cacheHasAttachments: !members.isEmpty)
        try fx.exec("""
            ALTER TABLE message ADD COLUMN is_sent INTEGER;
            ALTER TABLE message ADD COLUMN date_edited INTEGER;
            ALTER TABLE message ADD COLUMN date_retracted INTEGER;
            ALTER TABLE message ADD COLUMN message_summary_info BLOB;
            UPDATE message SET is_from_me=1,is_sent=1,date_edited=0,date_retracted=0 WHERE ROWID=60;
            """)
        for id in members { try fx.exec("INSERT INTO message_attachment_join VALUES(60,\(id))") }
        return fx
    }

    private func read(_ fx: ChatFixture, index: Int) throws -> MessagesUndoSendTargetSnapshot.Snapshot {
        try MessagesUndoSendTargetSnapshot.read(databasePath: fx.path, chat: .rowid(3),
            message: .rowid(60), partIndex: index, deadline: .millisecondsFromNow(5000),
            now: { Date(timeIntervalSinceReferenceDate: 800_000_010) })
    }

    @Test func mixedTextMayExcludeOnlyBoundAttachmentPlaceholder() throws {
        let fx = try fixture(text: "hello", body: "\u{fffc}hello",
                             runs: [(0, 1, 0, "a10"), (1, 5, 1, nil)])
        let attachment = try read(fx, index: 0)
        #expect(attachment.selectedAttachment?.rowid == 10)
        #expect(attachment.part.fullText.utf8.elementsEqual("\u{fffc}hello".utf8))
        let text = try read(fx, index: 1)
        #expect(text.selectedAttachment == nil)
        #expect(text.part.selectedTextFragments == ["hello"])
    }

    @Test func trailingAttachmentPreservesWhitespaceAndSupplementaryText() throws {
        let fx = try fixture(text: "\u{1f680} ", body: "\u{1f680} \u{fffc}",
                             runs: [(0, 3, 0, nil), (3, 1, 1, "a10")])
        #expect(try read(fx, index: 0).part.selectedTextFragments == ["\u{1f680} "])
        #expect(try read(fx, index: 1).selectedAttachment?.rowid == 10)
    }

    @Test func literalTextPlaceholderIsPreserved() throws {
        let fx = try fixture(text: "X\u{fffc}", body: "\u{fffc}X\u{fffc}",
                             runs: [(0, 1, 0, "a10"), (1, 2, 1, nil)])
        #expect(try read(fx, index: 1).part.selectedTextFragments == ["X\u{fffc}"])
    }

    @Test(arguments: ["X", "Y\u{fffc}", "X\u{fffc} "])
    func rejectsLiteralPlaceholderRemovalAndTextDrift(_ text: String) throws {
        let fx = try fixture(text: text, body: "\u{fffc}X\u{fffc}",
                             runs: [(0, 1, 0, "a10"), (1, 2, 1, nil)])
        #expect(throws: MessagesUndoSendPart.Failure.self) { try read(fx, index: 1) }
    }

    @Test func unmappedPlaceholderCannotBeRemoved() throws {
        let fx = try fixture(text: "hello", body: "\u{fffc}hello",
                             runs: [(1, 5, 1, nil)], members: [])
        #expect(throws: MessagesUndoSendPart.Failure.self) { try read(fx, index: 1) }
    }

    @Test func nonPlaceholderAttachmentPayloadCannotBeRemoved() throws {
        let fx = try fixture(text: "hello", body: "Xhello",
                             runs: [(0, 1, 0, "a10"), (1, 5, 1, nil)])
        #expect(throws: MessagesUndoSendPart.Failure.self) { try read(fx, index: 1) }
    }

    @Test func missingAttachmentMembershipStillRefuses() throws {
        let fx = try fixture(text: "hello", body: "\u{fffc}hello",
                             runs: [(0, 1, 0, "a10"), (1, 5, 1, nil)], members: [])
        #expect(throws: MessagesUndoSendAttachmentBinding.Failure.self) { try read(fx, index: 1) }
    }

    @Test func canonicalEquivalentTextDriftStillRefuses() throws {
        let fx = try fixture(text: "e\u{301}", body: "\u{fffc}\u{e9}",
                             runs: [(0, 1, 0, "a10"), (1, 1, 1, nil)])
        #expect(throws: MessagesUndoSendPart.Failure.self) { try read(fx, index: 1) }
    }
}
