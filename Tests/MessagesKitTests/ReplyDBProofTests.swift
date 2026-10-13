import Foundation
import SQLite3
import Testing
@testable import MessagesKit
import AppleKit

@Suite("ChatDB exact reply database proof", .serialized)
struct ReplyDBProofTests {
    private let friendBook = AddressBook(contacts: ["12125550100": "Friend Name"])

    private func makeDB(_ fx: ChatFixture) throws -> ChatDB {
        try ChatDB(path: fx.path, book: friendBook, copyToTemp: false, homeDirectoryForTilde: fx.homePath)
    }

    @Test func replyTargetAllowsIncomingDirectRootWithSingleResolvedParticipant() throws {
        let fx = try replyFixture()
        var db = try makeDB(fx)

        let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: nil)

        #expect(target.chat_rowid == 3)
        #expect(target.message_rowid == 60)
        #expect(target.message_guid == "reply-root")
        #expect(target.native_part == 2)
        #expect(target.part_guid == nil)
        #expect(target.participant_handle == "+12125550100")
        #expect(target.root_is_from_me == false)
    }

    @Test func replyTargetRejectsGroupMultiParticipantNestedAndAmbiguousPart() throws {
        let fx = try replyFixture()
        var db = try makeDB(fx)

        #expect(throws: (any Error).self) {
            _ = try db.exactReplyTarget(chat: .rowid(1), message: .rowid(70), partIndex: 2)
        }
        #expect(throws: (any Error).self) {
            _ = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(61), partIndex: 2)
        }
        #expect(throws: (any Error).self) {
            _ = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(62), partIndex: nil)
        }
        let explicit = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(62), partIndex: 4)
        #expect(explicit.native_part == 4)
    }

    @Test func replyHighwaterUsesSelectedChatMessageRowidsAndScanIsExclusiveOrderedAndOverflowAware() throws {
        let fx = try replyFixture()
        try insertReplyResult(fx, rowid: 40, guid: "old-direct", text: "old", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        try insertReplyResult(fx, rowid: 101, guid: "new-direct-a", text: "a", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        try insertReplyResult(fx, rowid: 100, guid: "new-direct-b", text: "b", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        try insertReplyResult(fx, rowid: 200, guid: "new-group", text: "group", chatRowid: 1, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        var db = try makeDB(fx)

        let highwater = try db.exactReplyHighwater(chatRowid: 3)
        #expect(highwater == 101)
        try insertReplyResult(fx, rowid: 102, guid: "after-a", text: "after", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        try insertReplyResult(fx, rowid: 104, guid: "after-c", text: "after", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        try insertReplyResult(fx, rowid: 103, guid: "after-b", text: "after", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        db = try makeDB(fx)

        let scan = try db.exactReplyRows(chatRowid: 3, afterHighwater: highwater)
        #expect(scan.overflow == false)
        #expect(scan.rows.map(\.rowid) == [102, 103, 104])

        for idx in 0..<129 {
            try insertReplyResult(fx, rowid: 300 + Int64(idx), guid: "overflow-\(idx)", text: "overflow", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        }
        db = try makeDB(fx)
        let overflow = try db.exactReplyRows(chatRowid: 3, afterHighwater: 299)
        #expect(overflow.overflow == true)
        #expect(overflow.rows_examined == 129)
    }

    @Test func replyProofVerifiesExactUTF8AndRejectsCanonicalUnicodeNearMatch() throws {
        let fx = try replyFixture()
        var db = try makeDB(fx)
        let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
        let highwater = try db.exactReplyHighwater(chatRowid: 3)
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        #expect(composed.utf8.elementsEqual(decomposed.utf8) == false)
        try insertReplyResult(fx, rowid: highwater + 1, guid: "unicode-near", text: decomposed, chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        try insertReplyResult(fx, rowid: highwater + 2, guid: "unicode-exact", text: composed, chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        db = try makeDB(fx)

        let proof = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                             target: target,
                                                             expectedText: composed)

        #expect(proof.status == "verified")
        #expect(proof.message_rowid == highwater + 2)
        #expect(proof.message_guid == "unicode-exact")
        #expect(proof.parent_message_guid == "reply-root")
        #expect(proof.parent_native_part == 2)
    }

    @Test func replyProofTreatsUnknownOutgoingBodyAsUncertainAndIgnoresIncomingOrUnrelatedRows() throws {
        let fx = try replyFixture()
        var db = try makeDB(fx)
        let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
        let highwater = try db.exactReplyHighwater(chatRowid: 3)
        try insertReplyResult(fx, rowid: highwater + 1, guid: "incoming-same-text", text: "sent", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 0)
        try insertReplyResult(fx, rowid: highwater + 2, guid: "outgoing-other", text: "different", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        db = try makeDB(fx)
        let waiting = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                               target: target,
                                                               expectedText: "sent")
        #expect(waiting.status == "waiting")

        try insertUnknownBodyReplyResult(fx, rowid: highwater + 3, guid: "unknown-body", chatRowid: 3,
                                         parentGUID: "reply-root", parentPart: "2")
        db = try makeDB(fx)
        let uncertain = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                                 target: target,
                                                                 expectedText: "sent")
        #expect(uncertain.status == "uncertain")
        #expect(uncertain.reason == "unknown-outgoing-body")
    }

    @Test func replyProofMarksTextMatchingMalformedWrongAssociationAndDuplicatesUncertain() throws {
        let cases: [(String, String?, String?, String)] = [
            ("missing-guid", nil, "2", "matching-row-missing-parent-guid"),
            ("wrong-guid", "other-root", "2", "matching-row-wrong-parent"),
            ("missing-part", "reply-root", nil, "matching-row-missing-parent-part"),
            ("wrong-part", "reply-root", "3", "matching-row-wrong-parent"),
            ("malformed-part", "reply-root", "03", "matching-row-malformed-parent"),
        ]

        for (name, parentGUID, parentPart, reason) in cases {
            let fx = try replyFixture()
            var db = try makeDB(fx)
            let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
            let highwater = try db.exactReplyHighwater(chatRowid: 3)
            try insertReplyResult(fx, rowid: highwater + 1, guid: name, text: "sent", chatRowid: 3,
                                  parentGUID: parentGUID, parentPart: parentPart, isFromMe: 1)
            db = try makeDB(fx)
            let proof = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                                 target: target,
                                                                 expectedText: "sent")
            #expect(proof.status == "uncertain")
            #expect(proof.reason == reason)
        }

        let fx = try replyFixture()
        var db = try makeDB(fx)
        let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
        let highwater = try db.exactReplyHighwater(chatRowid: 3)
        try insertReplyResult(fx, rowid: highwater + 1, guid: "dup-a", text: "sent", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        try insertReplyResult(fx, rowid: highwater + 2, guid: "dup-b", text: "sent", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        db = try makeDB(fx)
        let duplicate = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                                 target: target,
                                                                 expectedText: "sent")
        #expect(duplicate.status == "uncertain")
        #expect(duplicate.reason == "duplicate-matching-replies")
    }

    @Test func replyTargetRejectsMalformedAndUnknownDirectChatStyles() throws {
        for styleSQL in ["99", "45.5", "X'3435'", "'unsupported-style'", "NULL"] {
            let fx = try replyFixture()
            try fx.exec("UPDATE chat SET style = \(styleSQL) WHERE ROWID = 3;")
            var db = try makeDB(fx)
            #expect(throws: (any Error).self) {
                _ = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
            }
        }
    }

    @Test func replyTargetRejectsMalformedChatGuidAndParticipantJoinStorage() throws {
        do {
            let fx = try replyFixture()
            try fx.exec("UPDATE chat SET guid = X'6261642d67756964' WHERE ROWID = 3;")
            var db = try makeDB(fx)
            #expect(throws: (any Error).self) {
                _ = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
            }
        }

        do {
            let fx = try replyFixture()
            try weakenChatHandleJoinAffinity(fx)
            try fx.exec("DELETE FROM chat_handle_join WHERE chat_id = 3; INSERT INTO chat_handle_join VALUES ('3','1');")
            var db = try makeDB(fx)
            #expect(throws: (any Error).self) {
                _ = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
            }
        }
    }

    @Test func replyHighwaterAndScanRejectMalformedRawMembershipEvidence() throws {
        do {
            let fx = try replyFixture()
            try weakenChatMessageJoinAffinity(fx)
            try insertReplyResult(fx, rowid: 120, guid: "malformed-highwater", text: "sent", chatRowidSQL: "'3'", messageRowidSQL: "'120'", parentGUID: "reply-root", parentPart: "2", isFromMeSQL: "1")
            let db = try makeDB(fx)
            #expect(throws: (any Error).self) {
                _ = try db.exactReplyHighwater(chatRowid: 3)
            }
        }

        do {
            let fx = try replyFixture()
            var db = try makeDB(fx)
            let highwater = try db.exactReplyHighwater(chatRowid: 3)
            try weakenChatMessageJoinAffinity(fx)
            try insertReplyResult(fx, rowid: highwater + 1, guid: "malformed-scan", text: "sent", chatRowidSQL: "'3'", messageRowidSQL: "'\(highwater + 1)'", parentGUID: "reply-root", parentPart: "2", isFromMeSQL: "1")
            db = try makeDB(fx)
            #expect(throws: (any Error).self) {
                _ = try db.exactReplyRows(chatRowid: 3, afterHighwater: highwater)
            }
        }
    }

    @Test func replyProofRequiresByteExactParentGUIDMatch() throws {
        let fx = try replyFixture()
        let composed = "parent-caf\u{00e9}"
        let decomposed = "parent-cafe\u{0301}"
        #expect(composed.utf8.elementsEqual(decomposed.utf8) == false)
        try fx.exec("UPDATE message SET guid = \(sqlString(composed)) WHERE ROWID = 60;")
        var db = try makeDB(fx)
        let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
        let highwater = try db.exactReplyHighwater(chatRowid: 3)
        try insertReplyResult(fx, rowid: highwater + 1, guid: "unicode-parent", text: "sent", chatRowid: 3,
                              parentGUID: decomposed, parentPart: "2", isFromMe: 1)
        db = try makeDB(fx)
        let proof = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                             target: target,
                                                             expectedText: "sent")
        #expect(proof.status == "uncertain")
        #expect(proof.reason == "matching-row-wrong-parent")
    }

    @Test func replyProofRejectsLossyOutgoingOwnershipAndBodyEvidence() throws {
        do {
            let fx = try replyFixture()
            var db = try makeDB(fx)
            let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
            let highwater = try db.exactReplyHighwater(chatRowid: 3)
            try insertReplyResult(fx, rowid: highwater + 1, guid: "real-ownership", text: "sent", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMeSQL: "1.5")
            db = try makeDB(fx)
            let proof = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                                 target: target,
                                                                 expectedText: "sent")
            #expect(proof.status == "uncertain")
            #expect(proof.reason == "unknown-ownership")
        }

        do {
            let fx = try replyFixture()
            var db = try makeDB(fx)
            let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
            let highwater = try db.exactReplyHighwater(chatRowid: 3)
            try insertReplyResult(fx, rowid: highwater + 1, guid: "blob-text", textSQL: "X'73656e74'", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
            db = try makeDB(fx)
            let proof = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                                 target: target,
                                                                 expectedText: "sent")
            #expect(proof.status == "uncertain")
            #expect(proof.reason == "unknown-outgoing-body")
        }
    }

    @Test func replyProofRejectsMatchingRowsWithMissingGuidOrWrongChat() throws {
        let target = ChatDB.ExactReplyTarget(chat_rowid: 3, chat_guid: "chat-guid", message_rowid: 60,
                                            message_guid: "reply-root", native_part: 2, part_guid: nil,
                                            participant_handle: "+12125550100", root_is_from_me: false)
        let originator = ChatDB.ExactThreadOriginator(available: true, reason: "available",
                                                      message_guid: "reply-root", raw_part: "2", native_part: 2)
        let missingGUID = ChatDB.ExactReplyRow(rowid: 61, message_guid: nil, messageGUIDMalformed: false,
                                               selected_chat_rowid: 3, ownershipKnown: true, is_from_me: true,
                                               bodyKnown: true, body: "sent", thread_originator: originator)
        let missingProof = try ChatDB.judgeExactReplyCorrespondence(
            scan: ChatDB.ExactReplyRowScan(chat_rowid: 3, after_highwater: 60,
                                           row_limit: ChatDB.ExactReplyRowScan.rowLimit,
                                           rows_examined: 1, overflow: false, rows: [missingGUID]),
            target: target,
            expectedText: "sent")
        #expect(missingProof.status == "uncertain")
        #expect(missingProof.reason == "matching-row-missing-guid")

        let wrongChat = ChatDB.ExactReplyRow(rowid: 62, message_guid: "result", messageGUIDMalformed: false,
                                             selected_chat_rowid: 4, ownershipKnown: true, is_from_me: true,
                                             bodyKnown: true, body: "sent", thread_originator: originator)
        let wrongChatProof = try ChatDB.judgeExactReplyCorrespondence(
            scan: ChatDB.ExactReplyRowScan(chat_rowid: 3, after_highwater: 60,
                                           row_limit: ChatDB.ExactReplyRowScan.rowLimit,
                                           rows_examined: 1, overflow: false, rows: [wrongChat]),
            target: target,
            expectedText: "sent")
        #expect(wrongChatProof.status == "uncertain")
        #expect(wrongChatProof.reason == "matching-row-wrong-chat")
    }

    @Test func replyProofOverflowCountsIncomingRowsBeforeFiltering() throws {
        let fx = try replyFixture()
        var db = try makeDB(fx)
        let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
        let highwater = try db.exactReplyHighwater(chatRowid: 3)
        for idx in 0..<129 {
            let rowid = Int64(1_000 + idx)
            try insertReplyResult(fx, rowid: rowid, guid: "incoming-overflow-\(idx)",
                                  text: "sent", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 0)
        }
        db = try makeDB(fx)
        let scan = try db.exactReplyRows(chatRowid: 3, afterHighwater: highwater)
        let proof = try ChatDB.judgeExactReplyCorrespondence(scan: scan, target: target, expectedText: "sent")
        #expect(scan.overflow == true)
        #expect(scan.rows_examined == 129)
        #expect(proof.status == "uncertain")
        #expect(proof.reason == "row-limit-exceeded")
    }

    @Test func replyProofUsesFreshScansForDelayedRows() throws {
        let fx = try replyFixture()
        var db = try makeDB(fx)
        let target = try db.exactReplyTarget(chat: .rowid(3), message: .rowid(60), partIndex: 2)
        let highwater = try db.exactReplyHighwater(chatRowid: 3)

        let first = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                             target: target,
                                                             expectedText: "sent")
        #expect(first.status == "waiting")

        try insertReplyResult(fx, rowid: highwater + 1, guid: "delayed", text: "sent", chatRowid: 3, parentGUID: "reply-root", parentPart: "2", isFromMe: 1)
        db = try makeDB(fx)
        let second = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: 3, afterHighwater: highwater),
                                                              target: target,
                                                              expectedText: "sent")
        #expect(second.status == "verified")
        #expect(second.message_guid == "delayed")
    }
}

private func replyFixture() throws -> ChatFixture {
    let fx = try ChatFixture()
    try fx.addThreadOriginatorColumns()
    let text = "Root text"
    let singlePart = nativeReplyArchive(text, [(replyNativePartKey, NSNumber(value: 2), nativeReplyRange(text, "Root"))])
    try fx.insertMessage(rowid: 60, guid: "reply-root", attributedBody: singlePart, chatRowid: 3, date: fx.base - 60)
    try fx.setThreadOriginator(rowid: 60, guidSQL: "NULL", partSQL: "NULL")

    let nested = nativeReplyArchive(text, [(replyNativePartKey, NSNumber(value: 2), nativeReplyRange(text, "Root"))])
    try fx.insertMessage(rowid: 61, guid: "nested-root", attributedBody: nested, chatRowid: 3, date: fx.base - 61)
    try fx.setThreadOriginator(rowid: 61, guidSQL: "'ancestor'", partSQL: "'2'")

    let multi = "First Second"
    let multiPart = nativeReplyArchive(multi, [
        (replyNativePartKey, NSNumber(value: 4), nativeReplyRange(multi, "First")),
        (replyNativePartKey, NSNumber(value: 5), nativeReplyRange(multi, "Second")),
    ])
    try fx.insertMessage(rowid: 62, guid: "multi-root", attributedBody: multiPart, chatRowid: 3, date: fx.base - 62)
    try fx.setThreadOriginator(rowid: 62, guidSQL: "NULL", partSQL: "NULL")

    try fx.insertMessage(rowid: 70, guid: "group-root", attributedBody: singlePart, chatRowid: 1, date: fx.base - 70)
    try fx.setThreadOriginator(rowid: 70, guidSQL: "NULL", partSQL: "NULL")
    return fx
}

private let replyNativePartKey = NSAttributedString.Key("__kIMMessagePartAttributeName")

private func nativeReplyArchive(_ text: String, _ attributes: [(NSAttributedString.Key, Any, NSRange)]) -> Data {
    let value = NSMutableAttributedString(string: text)
    for (key, object, range) in attributes { value.addAttribute(key, value: object, range: range) }
    return NSArchiver.archivedData(withRootObject: value)
}

private func nativeReplyRange(_ text: String, _ needle: String) -> NSRange {
    let range = (text as NSString).range(of: needle)
    precondition(range.location != NSNotFound)
    return range
}

private func sqlString(_ value: String?) -> String {
    guard let value else { return "NULL" }
    return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

private func insertReplyResult(_ fx: ChatFixture, rowid: Int64, guid: String?, text: String, chatRowid: Int64,
                               parentGUID: String?, parentPart: String?, isFromMe: Int) throws {
    try insertReplyResult(fx, rowid: rowid, guid: guid, textSQL: sqlString(text), chatRowidSQL: String(chatRowid),
                          messageRowidSQL: String(rowid), parentGUID: parentGUID, parentPart: parentPart,
                          isFromMeSQL: String(isFromMe))
}

private func insertReplyResult(_ fx: ChatFixture, rowid: Int64, guid: String?, text: String, chatRowid: Int64,
                               parentGUID: String?, parentPart: String?, isFromMeSQL: String) throws {
    try insertReplyResult(fx, rowid: rowid, guid: guid, textSQL: sqlString(text), chatRowidSQL: String(chatRowid),
                          messageRowidSQL: String(rowid), parentGUID: parentGUID, parentPart: parentPart,
                          isFromMeSQL: isFromMeSQL)
}

private func insertReplyResult(_ fx: ChatFixture, rowid: Int64, guid: String?, textSQL: String, chatRowid: Int64,
                               parentGUID: String?, parentPart: String?, isFromMe: Int) throws {
    try insertReplyResult(fx, rowid: rowid, guid: guid, textSQL: textSQL, chatRowidSQL: String(chatRowid),
                          messageRowidSQL: String(rowid), parentGUID: parentGUID, parentPart: parentPart,
                          isFromMeSQL: String(isFromMe))
}

private func insertReplyResult(_ fx: ChatFixture, rowid: Int64, guid: String?, text: String, chatRowidSQL: String,
                               messageRowidSQL: String, parentGUID: String?, parentPart: String?, isFromMeSQL: String) throws {
    try insertReplyResult(fx, rowid: rowid, guid: guid, textSQL: sqlString(text), chatRowidSQL: chatRowidSQL,
                          messageRowidSQL: messageRowidSQL, parentGUID: parentGUID, parentPart: parentPart,
                          isFromMeSQL: isFromMeSQL)
}

private func insertReplyResult(_ fx: ChatFixture, rowid: Int64, guid: String?, textSQL: String, chatRowidSQL: String,
                               messageRowidSQL: String, parentGUID: String?, parentPart: String?, isFromMeSQL: String) throws {
    try fx.exec("""
        INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,thread_originator_guid,thread_originator_part)
        VALUES (\(rowid),\(sqlString(guid)),\(textSQL),\(isFromMeSQL),1,'iMessage',\(fx.base + rowid),0,\(sqlString(parentGUID)),\(sqlString(parentPart)));
        INSERT INTO chat_message_join VALUES (\(chatRowidSQL),\(messageRowidSQL));
        """)
}

private func insertUnknownBodyReplyResult(_ fx: ChatFixture, rowid: Int64, guid: String, chatRowid: Int64,
                                          parentGUID: String, parentPart: String) throws {
    try fx.exec("""
        INSERT INTO message (ROWID,guid,attributedBody,is_from_me,handle_id,service,date,error,thread_originator_guid,thread_originator_part)
        VALUES (\(rowid),\(sqlString(guid)),X'000102',1,1,'iMessage',\(fx.base + rowid),0,\(sqlString(parentGUID)),\(sqlString(parentPart)));
        INSERT INTO chat_message_join VALUES (\(chatRowid),\(rowid));
        """)
}

private func weakenChatMessageJoinAffinity(_ fx: ChatFixture) throws {
    try fx.exec("""
        ALTER TABLE chat_message_join RENAME TO chat_message_join_old;
        CREATE TABLE chat_message_join(chat_id, message_id);
        INSERT INTO chat_message_join SELECT chat_id, message_id FROM chat_message_join_old;
        DROP TABLE chat_message_join_old;
        """)
}

private func weakenChatHandleJoinAffinity(_ fx: ChatFixture) throws {
    try fx.exec("""
        ALTER TABLE chat_handle_join RENAME TO chat_handle_join_old;
        CREATE TABLE chat_handle_join(chat_id, handle_id);
        INSERT INTO chat_handle_join SELECT chat_id, handle_id FROM chat_handle_join_old;
        DROP TABLE chat_handle_join_old;
        """)
}
