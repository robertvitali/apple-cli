import Foundation
import AppleKit
import Testing
@testable import MessagesKit

@Suite struct NativeEditExactHistoryTests {
    private func summary(_ archived: Data, dataURL: Bool, exact: Bool = true) throws -> ChatDB.ExactNativeEditContext.Summary {
        let value: Any = dataURL ? "data:application/octet-stream;base64," + archived.base64EncodedString() : archived
        let data = try PropertyListSerialization.data(fromPropertyList:
            ["ec": ["0": [["d": 1, "t": value]]]], format: .binary, options: 0)
        var budget = NativeEditContextDecoder.Budget()
        return try NativeEditContextDecoder.decode(data, budget: &budget, requireExactHistoryText: exact)
    }

    @Test(arguments: [false, true])
    func changedHistoryBytesCannotProveAnEdit(_ dataURL: Bool) throws {
        let raw = Data("Synthetic history".utf8)
        var archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Synthetic history"))
        let span = try #require(archive.range(of: raw))
        try #require(span.lowerBound > 0)
        try #require(archive[span.lowerBound - 1] == UInt8(raw.count))
        archive[span.lowerBound - 1] = UInt8(raw.count + 3)
        archive.replaceSubrange(span, with: Data([0xef, 0xbb, 0xbf]) + raw)
        // Legacy display strips the injected BOM. Mutation evidence must not.
        #expect(NativeMessageParts.decode(archive).text == "Synthetic history")
        let legacy = try summary(archive, dataURL: dataURL, exact: false)
        #expect(legacy.edit_history.entries?.first?.events?.first?.body.text == "Synthetic history")
        let decoded = try summary(archive, dataURL: dataURL)
        let event = try #require(decoded.edit_history.entries?.first?.events?.first)
        #expect(event.body.status == "decode-unavailable")
        #expect(event.body.text == nil)
        #expect(event.body.reason == "changed-root-text-bytes")
    }
    @Test(arguments: ["", "Synthetic history", "e\u{301}", "\u{e9}", "Synthetic 🐝"], [false, true])
    func exactHistoryRetainsUnchangedUTF8(_ text: String, _ dataURL: Bool) throws {
        let archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
        let decoded = try summary(archive, dataURL: dataURL)
        let event = try #require(decoded.edit_history.entries?.first?.events?.first)
        #expect(event.body.status == "available")
        let actual = try #require(event.body.text)
        #expect(Data(actual.utf8) == Data(text.utf8))
        #expect(event.body.reason == nil)
    }

    @Test func boundedReadForwardsStrictModeWithoutChangingDefault() throws {
        let raw = Data("Synthetic history".utf8)
        var archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Synthetic history"))
        let span = try #require(archive.range(of: raw))
        try #require(span.lowerBound > 0 && archive[span.lowerBound - 1] == UInt8(raw.count))
        archive[span.lowerBound - 1] = UInt8(raw.count + 3)
        archive.replaceSubrange(span, with: Data([0xef, 0xbb, 0xbf]) + raw)
        let data = try PropertyListSerialization.data(fromPropertyList:
            ["ec": ["0": [["d": 1, "t": archive]]]], format: .binary, options: 0)
        let row = SQLiteReader.Row(values: [
            "rowid": .integer(1), "selected_chat_rowid": .integer(3),
            "message_guid": .text("synthetic-message"), "chat_guid": .text("synthetic-chat"),
            "native_edit_summary_type": .text("blob"),
            "native_edit_summary_length": .integer(Int64(data.count)),
            "native_edit_summary_blob": .blob(data)
        ])
        var legacyBudget = NativeEditContextRead.Budget()
        let legacy = try NativeEditContextRead.context(row, requested: true, budget: &legacyBudget,
            read: { _, _ in [row] })
        #expect(legacy.summary_info.edit_history.entries?.first?.events?.first?.body.text == "Synthetic history")
        var strictBudget = NativeEditContextRead.Budget()
        let strict = try NativeEditContextRead.context(row, requested: true, budget: &strictBudget,
            requireExactHistoryText: true, read: { _, _ in [row] })
        let event = try #require(strict.summary_info.edit_history.entries?.first?.events?.first)
        #expect(event.body.status == "decode-unavailable")
        #expect(event.body.text == nil)
        #expect(event.body.reason == "changed-root-text-bytes")
        #expect(strictBudget.remainingInputBytes == 4_194_304 - data.count)
    }

}
