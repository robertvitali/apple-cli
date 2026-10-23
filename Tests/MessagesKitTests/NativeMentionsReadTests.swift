import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct NativeMentionsReadTests {
    private let mention = NSAttributedString.Key("__kIMMentionConfirmedMention")
    private let part = NSAttributedString.Key("__kIMMessagePartAttributeName")

    private func blob(_ text: String = "👋 Alice", identifier: Any = "alice@example.com",
                      range: NSRange = .init(location: 3, length: 5)) -> Data {
        let value = NSMutableAttributedString(string: text)
        value.addAttribute(mention, value: identifier, range: range)
        return NSArchiver.archivedData(withRootObject: value)
    }

    private func context(_ data: Data, budget: inout NativeMentionsRead.Budget) -> ChatDB.ExactNativeMentions {
        NativeMentionsRead.context(.blob(data), decoded: NativeMessageParts.decode(data, collectMentions: true),
                                  requested: true, budget: &budget)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func explicitWireKeysUseOriginalTextAndUTF16Ranges() throws {
        var budget = NativeMentionsRead.Budget()
        let result = context(blob(), budget: &budget)
        let value = try json(result)
        #expect(Set(value.keys) == ["status", "reason", "text", "range_encoding", "entries"])
        #expect(value["status"] as? String == "available")
        #expect(value["reason"] is NSNull)
        #expect(value["range_encoding"] as? String == "utf-16")
        #expect(result.text == "👋 Alice")
        let entry = try #require(result.entries?.first)
        #expect(entry.identifier == "alice@example.com")
        #expect(entry.utf16_range == .init(location: 3, length: 5))
        #expect(Set(try json(entry).keys) == ["identifier", "utf16_range"])
        #expect(budget.remainingEntries == 2047)
        #expect(budget.remainingBytes == 4_194_304 - "👋 Alice".utf8.count - "alice@example.com".utf8.count)
    }

    @Test func knownEmptyIsDistinctFromUnavailableAndCostsNothing() throws {
        var budget = NativeMentionsRead.Budget(remainingEntries: 0, remainingBytes: 0)
        let data = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "No mention"))
        let result = context(data, budget: &budget)
        #expect(result.status == "available")
        #expect(result.entries?.isEmpty == true)
        #expect(result.text == nil)
        #expect(!budget.exhausted)
        let value = try json(result)
        #expect(value["text"] is NSNull && value["reason"] is NSNull)
        #expect((value["entries"] as? [Any])?.isEmpty == true)
    }

    @Test func storageTypesAndRequestOptInAreExplicit() throws {
        let decoded = NativeMessageParts.decode(nil)
        let cases: [(SQLiteReader.Row.Value?, String, String)] = [
            (nil, "absent-blob", "absent-blob"), (.null, "absent-blob", "absent-blob"),
            (.text("synthetic"), "wrong-type", "wrong-storage-type"),
            (.blob(Data()), "corrupt", "native-parse-failed"),
            (.blob(Data(repeating: 0, count: 13)), "unsupported", "unsupported-typedstream"),
            (.integer(1), "wrong-type", "wrong-storage-type"),
            (.real(0.5), "wrong-type", "wrong-storage-type")
        ]
        for (value, status, reason) in cases {
            var budget = NativeMentionsRead.Budget()
            let parsed: NativeMessageParts.Decoded
            if case .blob(let data)? = value { parsed = NativeMessageParts.decode(data, collectMentions: true) }
            else { parsed = decoded }
            let result = NativeMentionsRead.context(value, decoded: parsed, requested: true, budget: &budget)
            #expect(result.status == status && result.reason == reason)
            let encoded = try json(result)
            #expect(encoded["text"] is NSNull && encoded["entries"] is NSNull)
            #expect(budget.remainingEntries == 2048 && budget.remainingBytes == 4_194_304)
        }
        var budget = NativeMentionsRead.Budget()
        let result = NativeMentionsRead.context(.blob(blob()), decoded: decoded, requested: false, budget: &budget)
        #expect(result.status == "not-requested")
        #expect(!NativeMentionsRead.shouldCollect(requested: false, budget: budget))
    }

    @Test func malformedMentionAndStreamNeverExposePartialOutput() {
        var budget = NativeMentionsRead.Budget()
        for (identifier, status, reason) in [("", "corrupt", "invalid-mention-identifier"),
            (String(repeating: "a", count: 1025), "resource-limit", "mention-identifier-limit")] {
            let result = context(blob(identifier: identifier), budget: &budget)
            #expect(result.status == status && result.reason == reason)
            #expect(result.entries == nil && result.text == nil)
        }
        var truncated = blob()
        truncated.removeLast()
        let result = context(truncated, budget: &budget)
        #expect(result.status == "corrupt" && result.reason == "native-parse-failed")
        #expect(budget.remainingEntries == 2048 && budget.remainingBytes == 4_194_304)
    }

    @Test func wholeMessageAdmissionStopsPermanentlyAfterFirstBudgetMiss() {
        let data = blob()
        let bytes = "👋 Alice".utf8.count + "alice@example.com".utf8.count
        for initial in [NativeMentionsRead.Budget(remainingEntries: 1, remainingBytes: bytes),
                        NativeMentionsRead.Budget(remainingEntries: 2, remainingBytes: bytes)] {
            var budget = initial
            #expect(context(data, budget: &budget).status == "available")
            let beforeEntries = budget.remainingEntries
            let beforeBytes = budget.remainingBytes
            let limited = context(data, budget: &budget)
            #expect(limited.status == "request-limit" && limited.reason == "request-budget-exhausted")
            #expect(limited.text == nil && limited.entries == nil)
            #expect(budget.remainingEntries == beforeEntries && budget.remainingBytes == beforeBytes)
            #expect(!NativeMentionsRead.shouldCollect(requested: true, budget: budget))
            let empty = NSArchiver.archivedData(withRootObject: NSAttributedString(string: ""))
            #expect(context(empty, budget: &budget).status == "request-limit")
        }
        var tooSmall = NativeMentionsRead.Budget(remainingEntries: 100, remainingBytes: bytes - 1)
        #expect(context(data, budget: &tooSmall).status == "request-limit")
        #expect(tooSmall.remainingEntries == 100 && tooSmall.remainingBytes == bytes - 1)
    }

    @Test func cachedAttributeReferenceEmitsEachOriginalRange() throws {
        var data = blob("Alice", range: .init(location: 0, length: 5))
        let initialRun = Data([0x84, 2, 0x69, 0x49, 1, 5])
        let range = try #require(data.range(of: initialRun))
        data.replaceSubrange(range, with: Data([0x84, 2, 0x69, 0x49, 1, 2]))
        // The second run reuses attrRef 1 without another dictionary object.
        data.insert(contentsOf: [0x84, 2, 0x69, 0x49, 1, 3], at: data.count - 1)
        var budget = NativeMentionsRead.Budget()
        let result = context(data, budget: &budget)
        #expect(result.status == "available" && result.text == "Alice")
        #expect(result.entries?.map(\.identifier) == ["alice@example.com", "alice@example.com"])
        #expect(result.entries?.map(\.utf16_range) == [.init(location: 0, length: 2), .init(location: 2, length: 3)])
        #expect(budget.remainingEntries == 2046)
    }

    private func database(_ fixture: ChatFixture) throws -> ChatDB {
        try ChatDB(path: fixture.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                   homeDirectoryForTilde: fixture.homePath)
    }

    private func install(_ data: Data, in fixture: ChatFixture, rowid: Int) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try fixture.exec("UPDATE message SET attributedBody=X'\(hex)' WHERE ROWID=\(rowid)")
    }

    @Test(arguments: ["17", "1.5", "'synthetic'"])
    func exactReadsDistinguishWrongSQLiteStorageFromAbsentArchive(_ value: String) throws {
        let fixture = try ChatFixture()
        try fixture.exec("UPDATE message SET attributedBody=\(value) WHERE ROWID=1")
        var db = try database(fixture)
        let result = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeMentions: true).1
        #expect(result.native_mentions.status == "wrong-type")
        #expect(result.native_mentions.reason == "wrong-storage-type")
        #expect(result.native_mentions.text == nil && result.native_mentions.entries == nil)
        #expect(result.native_parts_reason == "absent-blob")
        #expect(result.body == "hello from friend")
    }

    @Test func invalidUTF8StoragePreservesExistingQueryFailure() throws {
        let fixture = try ChatFixture()
        try fixture.exec("UPDATE message SET attributedBody=CAST(X'ff' AS TEXT) WHERE ROWID=1")
        var db = try database(fixture)
        for requested in [false, true] {
            #expect(throws: (any Error).self) {
                try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeMentions: requested)
            }
        }
    }

    @Test func exactReadOptInPreservesBodyAndCursorAndResetsBudget() throws {
        let fixture = try ChatFixture()
        for id in [1, 2, 3] { try install(blob(), in: fixture, rowid: id) }
        var db = try database(fixture)
        let original = try db.exactGet(chat: .rowid(3), message: .rowid(1)).1
        #expect(original.native_mentions.status == "not-requested")
        let enriched = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeMentions: true).1
        #expect(enriched.body == original.body)
        #expect(enriched.native_mentions.text == "👋 Alice")
        #expect(enriched.native_mentions.text != enriched.body)
        #expect(enriched.native_parts_available == original.native_parts_available)
        #expect(enriched.native_edit_context.summary_info.status == "not-requested")
        let defaultPage = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: nil)
        let page = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: nil, includeNativeMentions: true)
        let originalCursor = try #require(defaultPage.nextCursor)
        let enrichedCursor = try #require(page.nextCursor)
        let originalPayload = try #require(Data(base64Encoded: originalCursor))
        let enrichedPayload = try #require(Data(base64Encoded: enrichedCursor))
        let originalFields = try #require(JSONSerialization.jsonObject(with: originalPayload) as? [String: Any])
        let enrichedFields = try #require(JSONSerialization.jsonObject(with: enrichedPayload) as? [String: Any])
        #expect(NSDictionary(dictionary: originalFields).isEqual(to: enrichedFields))
        let originalNext = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: originalCursor)
        let enrichedNext = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc,
                                               cursor: enrichedCursor, includeNativeMentions: true)
        #expect(originalNext.items.map(\.rowid) == enrichedNext.items.map(\.rowid))
        #expect(page.items.map(\.rowid) == defaultPage.items.map(\.rowid))
        let message = try #require(page.items.first)
        let exact = try db.exactGet(chat: .rowid(3), message: .rowid(message.rowid), includeNativeMentions: true).1
        #expect(try NSDictionary(dictionary: json(message.native_mentions)).isEqual(to: json(exact.native_mentions)))
    }

    @Test func cancelledPublicEnrichmentPropagatesCancellation() async throws {
        let task = Task { () throws -> String in
            let fixture = try ChatFixture()
            var db = try ChatDB(path: fixture.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                                homeDirectoryForTilde: fixture.homePath)
            withUnsafeCurrentTask { $0?.cancel() }
            return try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeMentions: true).1.native_mentions.status
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled native mention enrichment returned a result")
        } catch is CancellationError {
            // Cancellation remains a command failure, not unavailable metadata.
        }
    }

    @Test func longAttributedTextUsesItsOwnRangeBasisWithoutChangingLegacyFallback() throws {
        let fixture = try ChatFixture()
        let text = String(repeating: "x", count: 70_000) + "👋 Alice"
        let data = blob(text, range: .init(location: 70_003, length: 5))
        try install(data, in: fixture, rowid: 1)
        try fixture.exec("UPDATE message SET text=NULL WHERE ROWID=1")
        var db = try database(fixture)
        let old = try db.exactGet(chat: .rowid(3), message: .rowid(1)).1
        let enriched = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeMentions: true).1
        #expect(enriched.body == old.body)
        #expect(enriched.body == AttributedBody.decode(data))
        #expect(enriched.native_mentions.text == text)
        #expect(enriched.native_mentions.text != enriched.body)
        #expect(enriched.native_mentions.entries?.first?.utf16_range == .init(location: 70_003, length: 5))
    }

    @Test func requestContentByteLimitIsIndependentOfEntryLimit() throws {
        let fixture = try ChatFixture()
        let text = String(repeating: "é", count: 125_000)
        let data = blob(text, range: .init(location: 0, length: 1))
        for id in 100...116 {
            try fixture.exec("""
                INSERT INTO message(ROWID,guid,text,is_from_me,handle_id,service,date,error)
                VALUES (\(id),'synthetic-byte-\(id)','Synthetic body',0,1,'iMessage',\(fixture.base + Int64(id)),0);
                INSERT INTO chat_message_join VALUES (3,\(id));
                """)
            try install(data, in: fixture, rowid: id)
        }
        var db = try database(fixture)
        let page = try db.exactHistory(chat: .rowid(3), limit: 17, order: .desc, cursor: nil, includeNativeMentions: true)
        #expect(page.items.prefix(16).allSatisfy { $0.native_mentions.entries?.count == 1 })
        #expect(page.items.last?.native_mentions.status == "request-limit")
        #expect(page.items.last?.native_mentions.text == nil)
        #expect(page.items.allSatisfy { $0.body == "Synthetic body" })
    }

    @Test func requestEntryLimitKeepsPageAndMessageBodies() throws {
        let fixture = try ChatFixture()
        let a = NSMutableAttributedString(string: String(repeating: "A", count: 256))
        a.addAttribute(mention, value: "alice@example.com", range: .init(location: 0, length: 256))
        for i in 0..<256 { a.addAttribute(part, value: NSNumber(value: i % 2), range: .init(location: i, length: 1)) }
        let data = NSArchiver.archivedData(withRootObject: a)
        for id in 100...109 {
            try fixture.exec("""
                INSERT INTO message(ROWID,guid,text,is_from_me,handle_id,service,date,error)
                VALUES (\(id),'synthetic-\(id)','Synthetic body',0,1,'iMessage',\(fixture.base + Int64(id)),0);
                INSERT INTO chat_message_join VALUES (3,\(id));
                """)
            try install(data, in: fixture, rowid: id)
        }
        var db = try database(fixture)
        let page = try db.exactHistory(chat: .rowid(3), limit: 10, order: .desc, cursor: nil, includeNativeMentions: true)
        #expect(page.items.count == 10 && page.nextCursor != nil)
        #expect(page.items.prefix(8).allSatisfy { $0.native_mentions.entries?.count == 256 })
        #expect(page.items.suffix(2).allSatisfy { $0.native_mentions.status == "request-limit" })
        #expect(page.items.allSatisfy { $0.body == "Synthetic body" && $0.native_parts_available })
        let last = try #require(page.items.last)
        let reset = try db.exactGet(chat: .rowid(3), message: .rowid(last.rowid), includeNativeMentions: true).1
        #expect(reset.native_mentions.entries?.count == 256)
    }

    @Test func sqliteEmptyBlobIsCorruptAndDistinctFromNullAndKnownEmpty() throws {
        let emptyArchive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "No mention"))
        let hex = emptyArchive.map { String(format: "%02x", $0) }.joined()
        let truncatedHex = emptyArchive.dropLast().map { String(format: "%02x", $0) }.joined()
        for (sql, status, reason) in [("NULL", "absent-blob", "absent-blob"),
                                      ("X''", "corrupt", "native-parse-failed"),
                                      ("X'\(truncatedHex)'", "corrupt", "native-parse-failed"),
                                      ("X'\(hex)'", "available", nil)] {
            let fixture = try ChatFixture()
            try fixture.exec("UPDATE message SET attributedBody=\(sql) WHERE ROWID=1")
            var db = try database(fixture)
            let old = try db.exactGet(chat: .rowid(3), message: .rowid(1)).1
            let exact = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeMentions: true).1
            let page = try db.exactHistory(chat: .rowid(3), limit: 100, order: .desc,
                                           cursor: nil, includeNativeMentions: true)
            let history = try #require(page.items.first { $0.rowid == 1 })
            for item in [exact, history] {
                #expect(item.native_mentions.status == status)
                #expect(item.native_mentions.reason == reason)
                #expect(item.native_mentions.text == nil)
                if status == "available" { #expect(item.native_mentions.entries?.isEmpty == true) }
                else { #expect(item.native_mentions.entries == nil) }
                #expect(item.body == old.body)
                #expect(item.native_parts_available == old.native_parts_available)
                #expect(item.native_parts_reason == old.native_parts_reason)
            }
        }
    }
}
