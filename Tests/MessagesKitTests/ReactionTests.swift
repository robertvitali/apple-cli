import Foundation
import Testing
@testable import MessagesKit
import AppleKit

private let reactionPartKey = NSAttributedString.Key("__kIMMessagePartAttributeName")

private func reactionNativeArchive(_ text: String, parts: [(Int, NSRange)]) -> Data {
    let value = NSMutableAttributedString(string: text)
    for (part, range) in parts {
        value.addAttribute(reactionPartKey, value: NSNumber(value: part), range: range)
    }
    return NSArchiver.archivedData(withRootObject: value)
}

private func reactionRange(_ text: String, _ needle: String) -> NSRange {
    let ns = text as NSString
    let range = ns.range(of: needle)
    precondition(range.location != NSNotFound)
    return range
}

private extension ChatFixture {
    func addReactionColumns(includeCustomEmoji: Bool = true) throws {
        try exec("ALTER TABLE message ADD COLUMN associated_message_guid TEXT;")
        try exec("ALTER TABLE message ADD COLUMN associated_message_type INTEGER;")
        if includeCustomEmoji {
            try exec("ALTER TABLE message ADD COLUMN associated_message_emoji TEXT;")
        }
    }

    func insertReaction(rowid: Int64, guid: String, associatedGUID: String, type: Int?,
                        isFromMe: Int? = 1, handleID: Int64? = 1, date: Int64?,
                        chatRowid: Int64 = 3, emoji: String? = nil) throws {
        let handleSQL = handleID.map(String.init) ?? "NULL"
        let emojiSQL = emoji.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        let fromMeSQL = isFromMe.map(String.init) ?? "NULL"
        let dateSQL = date.map(String.init) ?? "NULL"
        let typeSQL = type.map(String.init) ?? "NULL"
        let guidSQL = guid.replacingOccurrences(of: "'", with: "''")
        let associatedSQL = associatedGUID.replacingOccurrences(of: "'", with: "''")
        try exec("""
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,
                associated_message_guid,associated_message_type,associated_message_emoji)
            VALUES (\(rowid),'\(guidSQL)',NULL,\(fromMeSQL),\(handleSQL),'iMessage',\(dateSQL),0,
                '\(associatedSQL)',\(typeSQL),\(emojiSQL));
            INSERT INTO chat_message_join VALUES (\(chatRowid),\(rowid));
            """)
    }
}

@Suite("Exact reaction inspection")
struct ExactReactionInspectTests {
    private func makeDB(_ fx: ChatFixture) throws -> ChatDB {
        try ChatDB(path: fx.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                   homeDirectoryForTilde: fx.homePath)
    }

    @Test func missingReactionColumnsReportsUnavailable() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx)

        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(1))

        #expect(result.status == "unavailable")
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.reactions_by_author.isEmpty)
        #expect(result.evidence.unknown_reasons.contains("missing-reaction-column:associated_message_guid"))
    }

    @Test func foldsCurrentReactionPerAuthorAndIgnoresStaleRemoval() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        let text = "left right"
        let body = reactionNativeArchive(text, parts: [(2, reactionRange(text, "right"))])
        try fx.insertMessage(rowid: 70, guid: "target-guid", text: text, attributedBody: body,
                             chatRowid: 3, date: fx.base + 10)
        try fx.insertReaction(rowid: 100, guid: "reaction-heart", associatedGUID: "p:2/target-guid",
                              type: 2000, isFromMe: 1, date: fx.base + 20)
        try fx.insertReaction(rowid: 101, guid: "reaction-like", associatedGUID: "p:2/target-guid",
                              type: 2001, isFromMe: 1, date: fx.base + 30)
        try fx.insertReaction(rowid: 102, guid: "reaction-stale-remove", associatedGUID: "p:2/target-guid",
                              type: 3000, isFromMe: 1, date: fx.base + 40)
        try fx.insertReaction(rowid: 103, guid: "reaction-other", associatedGUID: "p:2/target-guid",
                              type: 2003, isFromMe: 0, handleID: 2, date: fx.base + 50)
        try fx.insertReaction(rowid: 104, guid: "wrong-chat", associatedGUID: "p:2/target-guid",
                              type: 2005, isFromMe: 1, date: fx.base + 60, chatRowid: 1)
        var db = try makeDB(fx)

        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70), rowLimit: 10)

        #expect(result.status == "ok")
        #expect(result.target.part_index == 2)
        #expect(result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "present")
        #expect(result.current_outgoing.key == "like")
        let selfState = try #require(result.reactions_by_author.first { $0.author.kind == "self" })
        #expect(selfState.current?.key == "like")
        #expect(selfState.events.map(\.reaction.key) == ["heart", "like", "heart"])
        let otherState = try #require(result.reactions_by_author.first { $0.author.kind == "other" })
        #expect(otherState.author.handle_id == 2)
        #expect(otherState.current?.key == "laugh")
        #expect(result.evidence.rows_examined == 4)
    }

    @Test func multipartTargetWithoutExplicitPartIsAmbiguousAndOutgoingUnknown() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        let text = "left right"
        let body = reactionNativeArchive(text, parts: [
            (1, reactionRange(text, "left")),
            (2, reactionRange(text, "right")),
        ])
        try fx.insertMessage(rowid: 80, guid: "multi-target", text: text, attributedBody: body,
                             chatRowid: 3, date: fx.base + 10)
        try fx.insertReaction(rowid: 110, guid: "reaction-left", associatedGUID: "p:1/multi-target",
                              type: 2001, isFromMe: 1, date: fx.base + 20)
        try fx.insertReaction(rowid: 111, guid: "reaction-right", associatedGUID: "p:2/multi-target",
                              type: 2002, isFromMe: 1, date: fx.base + 30)
        var db = try makeDB(fx)

        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(80), rowLimit: 10)

        #expect(result.status == "ambiguous")
        #expect(result.target.part_index == nil)
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.unknown_reasons.contains("multiple-native-parts-require-explicit-part"))
    }

    @Test func strictParticipantHandlesRejectsDanglingJoin() throws {
        let fx = try ChatFixture()
        try fx.exec("INSERT INTO chat_handle_join VALUES (3,999);")
        let db = try makeDB(fx)

        #expect(throws: AppleError.self) {
            _ = try db.exactParticipantHandles(chatRowid: 3)
        }
    }

    private func targetFixture(multipart: Bool = false, guid: String = "target-guid") throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        let text = "left right"
        let parts = multipart
            ? [(1, reactionRange(text, "left")), (2, reactionRange(text, "right"))]
            : [(2, reactionRange(text, "right"))]
        try fx.insertMessage(rowid: 70, guid: guid, text: text,
                             attributedBody: reactionNativeArchive(text, parts: parts),
                             chatRowid: 3, date: fx.base)
        return fx
    }

    @Test(arguments: [2008, 3008, 9999, Int.min, Int.max, nil] as [Int?])
    func unknownAssociatedTypesRemainEvidenceAndBlockMutation(type: Int?) throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "unknown-event", associatedGUID: "p:2/target-guid",
                              type: type, date: fx.base + 10)
        // Later supported events cannot erase unknown historical semantics.
        try fx.insertReaction(rowid: 101, guid: "known-event", associatedGUID: "p:2/target-guid",
                              type: 2001, date: fx.base + 20)
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.status == "ambiguous")
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.rows_examined == 2)
        #expect(result.evidence.unknown_reasons.contains("unknown-reaction-type"))
        let state = try #require(result.reactions_by_author.first)
        #expect(state.author.kind == "self")
        #expect(state.status == "unknown")
        #expect(state.current == nil)
        #expect(state.events.count == 2)
        #expect(state.events.first?.action == "unknown")
        #expect(state.events.first?.reaction.supported == false)
        #expect(state.events.first?.reaction.key == "unsupported:type:\(type.map(String.init) ?? "unknown")")
    }

    @Test(arguments: [2000, 3000], [false, true])
    func nullTimestampPoisonsAuthorFold(type: Int, includeDatedEvents: Bool) throws {
        for fromMe in [0, 1] {
            let fx = try targetFixture()
            try fx.insertReaction(rowid: 100, guid: "undated", associatedGUID: "p:2/target-guid",
                                  type: type, isFromMe: fromMe, date: nil)
            if includeDatedEvents {
                try fx.insertReaction(rowid: 101, guid: "dated-add", associatedGUID: "p:2/target-guid",
                                      type: 2000, isFromMe: fromMe, date: fx.base + 10)
                try fx.insertReaction(rowid: 102, guid: "dated-remove", associatedGUID: "p:2/target-guid",
                                      type: 3000, isFromMe: fromMe, date: fx.base + 20)
            }
            var db = try makeDB(fx)
            let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
            #expect(!result.target.mutation_eligible)
            #expect(result.current_outgoing.status == (fromMe == 1 ? "unknown" : "absent"))
            #expect(result.evidence.unknown_reasons.contains("null-reaction-timestamp"))
            let state = try #require(result.reactions_by_author.first)
            #expect(state.status == "unknown")
            #expect(state.current == nil)
            #expect(state.events.count == (includeDatedEvents ? 3 : 1))
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            #expect(json["current"] is NSNull)
            let events = try #require(json["events"] as? [[String: Any]])
            #expect(events[0]["normalized_seconds"] is NSNull)
            #expect(events[0]["normalized_nanoseconds"] is NSNull)
        }
    }

    @Test(arguments: ["target-guid", "bp:target-guid", "p:2/target-guid", "p:2/bp:target-guid"],
          ["target-guid", "bp:target-guid", "p:2/target-guid", "p:2/bp:target-guid"])
    func aliasInteractionsNeverMapBareEventsToNativeParts(addAlias: String, removeAlias: String) throws {
        for multipart in [false, true] {
            let fx = try targetFixture(multipart: multipart)
            try fx.insertReaction(rowid: 100, guid: "add", associatedGUID: addAlias,
                                  type: 2001, date: fx.base + 10)
            try fx.insertReaction(rowid: 101, guid: "remove", associatedGUID: removeAlias,
                                  type: 3001, date: fx.base + 20)
            try fx.insertReaction(rowid: 102, guid: "other-part", associatedGUID: "p:1/target-guid",
                                  type: 9999, date: fx.base + 30)
            var db = try makeDB(fx)
            let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70),
                                                   partIndex: multipart ? 2 : nil)
            let bare = !addAlias.hasPrefix("p:") || !removeAlias.hasPrefix("p:")
            #expect(result.target.part_index == 2)
            #expect(result.current_outgoing.status == (bare ? "unknown" : "absent"))
            #expect(result.target.mutation_eligible == !bare)
            #expect(result.evidence.rows_examined == 2)
            let state = try #require(result.reactions_by_author.first)
            #expect(state.status == (bare ? "unknown" : "absent"))
            #expect(state.current == nil)
            #expect(state.events.map(\.associated_message_guid) == [addAlias, removeAlias])
        }
    }

    @Test(arguments: ["NULL", "2", "-1", "0.5", "1.5", "'invalid'", "1e100"])
    func invalidFromMeFlagCannotBecomeOther(flagSQL: String) throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "invalid-author", associatedGUID: "p:2/target-guid",
                              type: 2000, handleID: 2, date: fx.base + 10)
        try fx.exec("UPDATE message SET is_from_me = \(flagSQL) WHERE ROWID = 100;")
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.current_outgoing.status == "unknown")
        #expect(!result.target.mutation_eligible)
        let state = try #require(result.reactions_by_author.first)
        #expect(state.author.kind == "unknown")
        #expect(state.author.is_from_me == nil)
        #expect(state.status == "unknown")
        #expect(state.current == nil)
    }

    @Test(arguments: [2007, 3007])
    func stickerEventsAreUnsupportedAndUnknown(type: Int) throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "sticker", associatedGUID: "p:2/target-guid",
                              type: type, date: fx.base + 10)
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.current_outgoing.status == "unknown")
        #expect(!result.target.mutation_eligible)
        let event = try #require(result.reactions_by_author.first?.events.first)
        #expect(event.action == (type == 2007 ? "add" : "remove"))
        #expect(event.reaction.key == "unsupported:sticker")
        #expect(!event.reaction.supported)
    }

    @Test(arguments: [false, true])
    func globalDuplicateGUIDPreventsMutation(hasOutgoing: Bool) throws {
        let fx = try targetFixture()
        try fx.insertMessage(rowid: 71, guid: "target-guid", chatRowid: 1, date: fx.base)
        if hasOutgoing {
            try fx.insertReaction(rowid: 100, guid: "outgoing", associatedGUID: "p:2/target-guid",
                                  type: 2000, date: fx.base + 10)
        }
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.unknown_reasons.contains("target-guid-not-globally-unique"))
    }

    @Test(arguments: [
        ("target-guid", "bp:target-guid", "p:2/bp:target-guid"),
        ("bp:target-guid", "target-guid", "p:2/bp:target-guid"),
        ("target-guid", "p:2/target-guid", "p:2/target-guid"),
        ("target-guid", "p:2/bp:target-guid", "p:2/bp:target-guid"),
        ("p:7/target-guid", "target-guid", "p:7/target-guid"),
        ("p:7/bp:target-guid", "target-guid", "p:7/bp:target-guid"),
        ("bp:p:7/target-guid", "p:7/target-guid", "p:2/bp:p:7/target-guid"),
        ("bp:target-guid", "bp:bp:target-guid", "p:2/bp:bp:target-guid"),
    ], [false, true])
    func equivalentAliasOwnersPreventFalseAbsence(collision: (String, String, String), hasEvents: Bool) throws {
        for otherChat in [Int64(1), Int64(3)] {
            let fx = try targetFixture(guid: collision.0)
            try fx.insertMessage(rowid: 71, guid: collision.1, chatRowid: otherChat, date: fx.base)
            if hasEvents {
                try fx.insertReaction(rowid: 100, guid: "target-add", associatedGUID: "p:2/\(collision.0)",
                                      type: 2001, date: fx.base + 10)
                try fx.insertReaction(rowid: 101, guid: "ambiguous-remove", associatedGUID: collision.2,
                                      type: 3001, date: fx.base + 20)
            }
            var db = try makeDB(fx)
            let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
            #expect(!result.target.mutation_eligible)
            #expect(result.current_outgoing.status == "unknown")
            #expect(result.evidence.unknown_reasons.contains("ambiguous-reaction-alias-ownership"))
            #expect(result.reactions_by_author.allSatisfy { $0.status == "unknown" && $0.current == nil })
        }
    }

    @Test(arguments: [
        "NULL", "''", "CAST(X'6368617400737566666978' AS TEXT)",
        "CAST(X'636861740A' AS TEXT)", "CAST(X'636861747F' AS TEXT)",
        "CAST(X'63686174C285' AS TEXT)", "CAST(X'63686174E2808D' AS TEXT)",
    ], [false, true])
    func unsafeStoredChatGUIDMakesOutgoingUnknown(guidSQL: String, hasOutgoing: Bool) throws {
        let fx = try targetFixture()
        try fx.exec("UPDATE chat SET guid = \(guidSQL) WHERE ROWID = 3;")
        if hasOutgoing {
            try fx.insertReaction(rowid: 100, guid: "outgoing", associatedGUID: "p:2/target-guid",
                                  type: 2000, date: fx.base + 10)
        }
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.unknown_reasons.contains(guidSQL == "NULL" ? "missing-target-chat-guid" : "unsafe-target-chat-guid"))
        #expect(result.reactions_by_author.allSatisfy { $0.status == "unknown" && $0.current == nil })
    }

    @Test(arguments: [false, true])
    func duplicateStoredChatGUIDMakesOutgoingUnknown(hasOutgoing: Bool) throws {
        let fx = try targetFixture()
        // The target belongs only to chat 3; an unrelated chat still makes its
        // native conversation GUID ambiguous when selection uses a ROWID.
        try fx.exec("UPDATE chat SET guid = (SELECT guid FROM chat WHERE ROWID = 3) WHERE ROWID = 1;")
        if hasOutgoing {
            try fx.insertReaction(rowid: 100, guid: "outgoing", associatedGUID: "p:2/target-guid",
                                  type: 2000, date: fx.base + 10)
        }
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.status == "ambiguous")
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.unknown_reasons.contains("target-chat-guid-not-globally-unique"))
        #expect(result.evidence.rows_examined == (hasOutgoing ? 1 : 0))
        #expect(result.reactions_by_author.allSatisfy { $0.status == "unknown" && $0.current == nil })
    }

    @Test(arguments: [
        "👍\u{200D}", "👍\u{0301}", "👍\u{20E3}", "❤🏻", "👍🏻🏻",
        "👍\u{FE0F}\u{FE0F}", "👩\u{200D}\u{200D}💻", "👩\u{200D}💻\u{0301}",
        "👍\u{200D}👍", "🏻", "🇦", "\u{1F9B0}",
    ], [false, true])
    func unsupportedCustomSequenceCannotEstablishAbsence(emoji: String, addBeforeRemove: Bool) throws {
        let fx = try targetFixture()
        if addBeforeRemove {
            try fx.insertReaction(rowid: 100, guid: "custom-add", associatedGUID: "p:2/target-guid",
                                  type: 2006, date: fx.base + 10, emoji: emoji)
        }
        try fx.insertReaction(rowid: 101, guid: "custom-remove", associatedGUID: "p:2/target-guid",
                              type: 3006, date: fx.base + 20, emoji: emoji)
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        let state = try #require(result.reactions_by_author.first)
        #expect(state.status == "unknown")
        #expect(state.current == nil)
        #expect(state.events.count == (addBeforeRemove ? 2 : 1))
        #expect(state.events.allSatisfy { !$0.reaction.supported })
    }

    @Test(arguments: ["😀", "❤", "❤\u{FE0F}", "1\u{20E3}", "#\u{FE0F}\u{20E3}",
                      "👍🏻", "👩\u{200D}💻", "👨🏽\u{200D}💻", "🧑🏿\u{200D}💻"])
    func supportedCustomSequencesPreserveBytesAndFold(emoji: String) throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "custom-add", associatedGUID: "p:2/target-guid",
                              type: 2006, date: fx.base + 10, emoji: emoji)
        var db = try makeDB(fx)
        let added = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(added.target.mutation_eligible)
        #expect(added.current_outgoing.status == "present")
        #expect(Array(try #require(added.current_outgoing.reaction?.emoji).utf8) == Array(emoji.utf8))
        try fx.insertReaction(rowid: 101, guid: "custom-remove", associatedGUID: "p:2/target-guid",
                              type: 3006, date: fx.base + 20, emoji: emoji)
        // Each reader pins its snapshot; reopen after changing the synthetic store.
        var refreshedDB = try makeDB(fx)
        let removed = try refreshedDB.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(removed.evidence.rows_examined == 2)
        #expect(removed.target.mutation_eligible)
        #expect(removed.current_outgoing.status == "absent")
        #expect(removed.reactions_by_author.first?.events.allSatisfy {
            $0.reaction.supported && $0.reaction.emoji.map { Array($0.utf8) } == Array(emoji.utf8)
        } == true)
    }

    @Test(arguments: ["1", "NULL", "3.5", "1e100", "-1e100"], [false, true])
    func multipleOrUnknownChatMembershipPreventsMutation(chatSQL: String, hasOutgoing: Bool) throws {
        let fx = try targetFixture()
        try fx.exec("INSERT INTO chat_message_join VALUES (\(chatSQL),70);")
        if hasOutgoing {
            try fx.insertReaction(rowid: 100, guid: "outgoing", associatedGUID: "p:2/target-guid",
                                  type: 2000, date: fx.base + 10)
        }
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.unknown_reasons.contains("target-message-not-distinct-single-chat-member"))
    }

    @Test func rowLimitPlusOneMakesPartialFoldUnknown() throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "add", associatedGUID: "p:2/target-guid",
                              type: 2000, date: fx.base + 10)
        try fx.insertReaction(rowid: 101, guid: "remove", associatedGUID: "p:2/target-guid",
                              type: 3000, date: fx.base + 20)
        var db = try makeDB(fx)
        let limited = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70), rowLimit: 1)
        #expect(limited.evidence.rows_capped)
        #expect(limited.evidence.rows_examined == 1)
        #expect(limited.current_outgoing.status == "unknown")
        #expect(limited.reactions_by_author.first?.status == "unknown")
        #expect(limited.reactions_by_author.first?.current == nil)
        #expect(!limited.target.mutation_eligible)
        let complete = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70), rowLimit: 2)
        #expect(!complete.evidence.rows_capped)
        #expect(complete.current_outgoing.status == "absent")
        #expect(complete.target.mutation_eligible)
    }

    @Test(arguments: [("❤", "❤\u{FE0F}"), ("👍", "👍🏻"),
                      ("👩", "👩\u{200D}💻"), ("1\u{20E3}", "1\u{FE0F}\u{20E3}")])
    func customRemovalComparesExactBytes(variants: (String, String)) throws {
        for removeExact in [false, true] {
            let fx = try targetFixture()
            try fx.insertReaction(rowid: 100, guid: "custom-add", associatedGUID: "p:2/target-guid",
                                  type: 2006, date: fx.base + 10, emoji: variants.0)
            try fx.insertReaction(rowid: 101, guid: "custom-remove", associatedGUID: "p:2/target-guid",
                                  type: 3006, date: fx.base + 20, emoji: removeExact ? variants.0 : variants.1)
            var db = try makeDB(fx)
            let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
            #expect(result.target.mutation_eligible)
            #expect(result.current_outgoing.status == (removeExact ? "absent" : "present"))
            let events = try #require(result.reactions_by_author.first?.events)
            #expect(Array(try #require(events[0].reaction.emoji).utf8) == Array(variants.0.utf8))
            if !removeExact {
                #expect(Array(try #require(result.current_outgoing.reaction?.emoji).utf8) == Array(variants.0.utf8))
            }
        }
    }

    @Test(arguments: ["'nonsense'", "3.5", "1e100", "-1e100", "X'0102'"], [false, true])
    func malformedTimestampNeverEstablishesAbsence(dateSQL: String, includeDatedRemoval: Bool) throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "malformed-add", associatedGUID: "p:2/target-guid",
                              type: 2000, date: nil)
        try fx.exec("UPDATE message SET date = \(dateSQL) WHERE ROWID = 100;")
        if includeDatedRemoval {
            try fx.insertReaction(rowid: 101, guid: "dated-remove", associatedGUID: "p:2/target-guid",
                                  type: 3000, date: fx.base + 20)
        }
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.unknown_reasons.contains("invalid-reaction-timestamp"))
        let state = try #require(result.reactions_by_author.first)
        #expect(state.status == "unknown")
        #expect(state.current == nil)
        let event = try #require(state.events.first { $0.rowid == 100 })
        #expect(event.normalized_seconds == nil)
        #expect(event.normalized_nanoseconds == nil)
    }

    @Test(arguments: ["1e100", "-1e100"])
    func extremeTargetDateDoesNotCrashExactResolution(dateSQL: String) throws {
        let fx = try targetFixture()
        try fx.exec("UPDATE message SET date = \(dateSQL) WHERE ROWID = 70;")
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.message.rowid == 70)
    }

    @Test(arguments: [
        "CAST(X'F09F918D006578747261' AS TEXT)", // emoji + NUL + suffix, no C-string binding
        "CAST(X'00F09F918D' AS TEXT)",
        "'plain'", "'é'", "'👍👍'", "''", "NULL", "123", "3.5", "X'F09F918D'", "'1'", "'1️'",
    ], [2006, 3006])
    func malformedCustomEmojiIsUnknown(emojiSQL: String, type: Int) throws {
        let fx = try targetFixture()
        // No affinity: retain INTEGER/REAL storage to exercise typed rejection.
        try fx.exec("ALTER TABLE message DROP COLUMN associated_message_emoji;")
        try fx.exec("ALTER TABLE message ADD COLUMN associated_message_emoji;")
        try fx.insertReaction(rowid: 100, guid: "malformed-custom", associatedGUID: "p:2/target-guid",
                              type: type, date: fx.base + 10)
        try fx.exec("UPDATE message SET associated_message_emoji = \(emojiSQL) WHERE ROWID = 100;")
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.reactions_by_author.first?.status == "unknown")
        #expect(result.reactions_by_author.first?.events.first?.reaction.supported == false)
    }

    @Test func reactionValueAndOutgoingEqualityUseExactBytes() {
        let composed = ChatDB.ExactReactionValue(key: "custom:é", name: "custom", emoji: "é", supported: true)
        let decomposed = ChatDB.ExactReactionValue(key: "custom:e\u{0301}", name: "custom",
                                                 emoji: "e\u{0301}", supported: true)
        #expect(composed != decomposed)
        #expect(composed == composed)
        let a = ChatDB.ExactCurrentOutgoingReaction(status: "present", key: composed.key, reaction: composed)
        let b = ChatDB.ExactCurrentOutgoingReaction(status: "present", key: decomposed.key, reaction: decomposed)
        #expect(a != b)
        // Even a key-only value must not normalize byte-distinct reaction identities.
        #expect(ChatDB.ExactCurrentOutgoingReaction(status: "present", key: composed.key, reaction: nil)
                != ChatDB.ExactCurrentOutgoingReaction(status: "present", key: decomposed.key, reaction: nil))
    }

    @Test(arguments: ["", "target-guid\u{0}suffix", "target-guid\n", "target-guid\u{7F}", "target-guid\u{85}"])
    func unsafeStoredGUIDNeverBuildsAliases(guid: String) throws {
        let fx = try targetFixture()
        let hex = guid.utf8.map { String(format: "%02x", $0) }.joined()
        try fx.exec("UPDATE message SET guid = CAST(X'\(hex)' AS TEXT) WHERE ROWID = 70;")
        // A truncated bind would find this different target and its reaction.
        try fx.insertMessage(rowid: 71, guid: "target-guid", chatRowid: 3, date: fx.base)
        try fx.insertReaction(rowid: 100, guid: "different-target-reaction", associatedGUID: "p:2/target-guid",
                              type: 2000, date: fx.base + 10)
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.status == "ambiguous")
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.rows_examined == 0)
        #expect(result.reactions_by_author.isEmpty)
    }

    @Test func unsafeGUIDSelectorCannotResolveTruncatedPrefix() throws {
        let fx = try targetFixture()
        var db = try makeDB(fx)
        #expect(throws: AppleError.self) {
            try db.exactReactionInspect(chat: .rowid(3), message: .guid("target-guid\u{0}suffix"))
        }
    }

    @Test(arguments: ["3.0,70", "3,70.0"])
    func integralRealMembershipIsRejectedBeforeDeduplication(endpoints: String) throws {
        let fx = try targetFixture()
        // No affinity: INTEGER 3 and REAL 3.0 compare equal under SQLite DISTINCT.
        try fx.exec("""
            CREATE TABLE membership_without_affinity(chat_id, message_id);
            INSERT INTO membership_without_affinity SELECT chat_id, message_id FROM chat_message_join;
            DROP TABLE chat_message_join;
            ALTER TABLE membership_without_affinity RENAME TO chat_message_join;
            """)
        var baselineDB = try makeDB(fx)
        let baseline = try baselineDB.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(baseline.status == "ok")
        #expect(baseline.target.mutation_eligible)
        #expect(baseline.current_outgoing.status == "absent")
        #expect(baseline.evidence.unknown_reasons.isEmpty)

        try fx.exec("INSERT INTO chat_message_join VALUES (\(endpoints));")
        // Reopen the reader to inspect the malformed membership in a fresh snapshot.
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(!result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "unknown")
        #expect(result.evidence.unknown_reasons.contains("target-message-not-distinct-single-chat-member"))
    }

    @Test func affinitylessChatIDPreservesOutgoingReactionEvidence() throws {
        let fx = try targetFixture()
        try fx.exec("""
            CREATE TABLE membership_without_chat_affinity(chat_id, message_id INTEGER);
            INSERT INTO membership_without_chat_affinity SELECT chat_id, message_id FROM chat_message_join;
            DROP TABLE chat_message_join;
            ALTER TABLE membership_without_chat_affinity RENAME TO chat_message_join;
            """)
        try fx.insertReaction(rowid: 100, guid: "outgoing", associatedGUID: "p:2/target-guid",
                              type: 2000, date: fx.base + 10)
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.status == "ok")
        #expect(result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "present")
        #expect(result.current_outgoing.key == "heart")
        #expect(result.evidence.rows_examined == 1)
        #expect(result.evidence.unknown_reasons.isEmpty)
        let author = try #require(result.reactions_by_author.first)
        #expect(author.author.kind == "self")
        #expect(author.events.map(\.rowid) == [100])
    }

    @Test(arguments: [Int64.min, -10_000_000_001, -1, 0, 10_000_000_000, Int64.max])
    func validIntegerTimestampExtremesRemainOrderable(date: Int64) throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "dated", associatedGUID: "p:2/target-guid",
                              type: 2000, date: date)
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "present")
        let event = try #require(result.reactions_by_author.first?.events.first)
        if (-9_999_999_999...9_999_999_999).contains(date) {
            #expect(event.normalized_seconds == date)
            #expect(event.normalized_nanoseconds == 0)
        } else {
            #expect(event.normalized_seconds == date / 1_000_000_000 - (date % 1_000_000_000 < 0 ? 1 : 0))
            #expect(event.normalized_nanoseconds == (date % 1_000_000_000 + 1_000_000_000) % 1_000_000_000)
        }
    }

    @Test func duplicateIntegerMembershipStillNamesOneChat() throws {
        let fx = try targetFixture()
        try fx.exec("INSERT INTO chat_message_join VALUES (3,70);")
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.target.mutation_eligible)
        #expect(result.current_outgoing.status == "absent")
    }

    @Test(arguments: [2000, 2006, 3006])
    func absentOptionalEmojiColumnIsExplicit(type: Int) throws {
        let fx = try targetFixture()
        try fx.insertReaction(rowid: 100, guid: "reaction", associatedGUID: "p:2/target-guid",
                              type: type, date: fx.base + 10)
        try fx.exec("ALTER TABLE message DROP COLUMN associated_message_emoji;")
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.current_outgoing.status == (type == 2000 ? "present" : "unknown"))
        #expect(result.target.mutation_eligible == (type == 2000))
        let value = try #require(result.reactions_by_author.first?.events.first?.reaction)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(json["emoji"] is NSNull)
        if type != 2000 { #expect(result.evidence.unknown_reasons.contains("missing-custom-emoji")) }
    }

    @Test(arguments: [
        "DELETE FROM chat_handle_join WHERE chat_id = 3;",
        "INSERT INTO chat_handle_join VALUES (3,NULL);",
        "DROP TABLE chat_handle_join; CREATE TABLE chat_handle_join(chat_id, handle_id); INSERT INTO chat_handle_join VALUES (3.0,1);",
        "DROP TABLE chat_handle_join; CREATE TABLE chat_handle_join(chat_id, handle_id); INSERT INTO chat_handle_join VALUES (3,1.0);",
        "UPDATE handle SET id = NULL WHERE ROWID = 1;",
        "UPDATE handle SET id = '' WHERE ROWID = 1;",
        "DROP TABLE handle; CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id, service); INSERT INTO handle VALUES (1,12125550100,'iMessage');",
        "DROP TABLE chat_handle_join;",
        "ALTER TABLE chat_handle_join DROP COLUMN handle_id;",
    ])
    func strictParticipantsRefuseMissingEvidence(sql: String) throws {
        let fx = try ChatFixture()
        try fx.exec(sql)
        let db = try makeDB(fx)
        #expect(throws: (any Error).self) { try db.exactParticipantHandles(chatRowid: 3) }
    }

    @Test func strictParticipantsPreserveResolvedHandles() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx)
        #expect(try db.exactParticipantHandles(chatRowid: 1) == ["+12125550101", "+12125550102"])
    }

    @Test func requiredDatabaseFailureIsNotEmptyReactionState() throws {
        let fx = try targetFixture()
        try fx.exec("DROP TABLE chat_message_join;")
        var db = try makeDB(fx)
        #expect(throws: (any Error).self) {
            try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        }
    }

    @Test func exactAssociatedGUIDIsBoundAndNotPatternMatched() throws {
        let guid = "target'_%guid"
        let fx = try targetFixture(guid: guid)
        try fx.insertReaction(rowid: 100, guid: "matching", associatedGUID: "p:2/\(guid)",
                              type: 2001, date: fx.base + 10)
        try fx.insertReaction(rowid: 101, guid: "nonmatching", associatedGUID: "p:2/targetXYZguid",
                              type: 9999, date: fx.base + 20)
        var db = try makeDB(fx)
        let result = try db.exactReactionInspect(chat: .rowid(3), message: .rowid(70))
        #expect(result.target.mutation_eligible)
        #expect(result.current_outgoing.key == "like")
        #expect(result.evidence.rows_examined == 1)
    }
}
