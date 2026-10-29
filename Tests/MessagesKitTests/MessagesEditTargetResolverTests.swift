import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditTargetResolverTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: "apple-cli-test original")
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0),
                          range: NSRange(location: 0, length: body.length))
        try fx.insertMessage(rowid: 60, guid: "synthetic-edit", attributedBody: NSArchiver.archivedData(withRootObject: body), chatRowid: 3, date: fx.base)
        let summary = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        let hex = summary.map { String(format: "%02x", $0) }.joined()
        try fx.exec("""
            ALTER TABLE message ADD COLUMN is_sent INTEGER;
            ALTER TABLE message ADD COLUMN date_edited INTEGER;
            ALTER TABLE message ADD COLUMN date_retracted INTEGER;
            ALTER TABLE message ADD COLUMN message_summary_info BLOB;
            UPDATE message SET is_from_me=1,is_sent=1,date_edited=0,date_retracted=0,message_summary_info=X'\(hex)' WHERE ROWID=60;
            """)
        return fx
    }

    private func read(_ fx: ChatFixture) throws -> MessagesEditTargetResolver.Snapshot {
        try MessagesEditTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
            partIndex: 0, sandboxPrefix: "apple-cli-test", deadline: .millisecondsFromNow(5000))
    }

    @Test func capturesExactOwnSentPartAndSelectedMembership() throws {
        let fx = try fixture()
        try fx.exec("INSERT INTO chat_message_join VALUES(1,60)")
        let value = try read(fx)
        #expect(value.chatRowid == 3)
        #expect(value.messageGUID == "synthetic-edit")
        #expect(value.partText == "apple-cli-test original")
        #expect(value.editContext.summary_info.edit_history.status == "missing-key")
        #expect(value.participantHandles == ["+12125550100"])
    }

    @Test(arguments: [
        "UPDATE message SET is_from_me=0 WHERE ROWID=60",
        "UPDATE message SET is_sent=0 WHERE ROWID=60",
        "UPDATE message SET service='SMS' WHERE ROWID=60",
        "UPDATE message SET error=1 WHERE ROWID=60",
        "UPDATE message SET date_retracted=1 WHERE ROWID=60",
        "UPDATE message SET text='different body' WHERE ROWID=60",
        "INSERT INTO chat_message_join VALUES(3,60)",
        "INSERT INTO message(ROWID,guid) VALUES(61,'synthetic-edit')",
        "UPDATE message SET message_summary_info=zeroblob(1048577) WHERE ROWID=60",
        "ALTER TABLE message ADD COLUMN _rowid_ INTEGER"
    ]) func rejectsIneligibleAmbiguousOrUnboundedEvidence(_ sql: String) throws {
        let fx = try fixture()
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func identicalTextCannotSubstituteAnotherMessageIdentity() throws {
        let fx = try fixture()
        try fx.exec("""
            INSERT INTO message(ROWID,guid,text,attributedBody,is_from_me,is_sent,service,date,error,
                date_edited,date_retracted,message_summary_info)
            SELECT 61,'synthetic-other-edit',text,attributedBody,is_from_me,is_sent,service,date,error,
                date_edited,date_retracted,message_summary_info FROM message WHERE ROWID=60;
            INSERT INTO chat_message_join(chat_id,message_id) VALUES(3,61);
            """)
        let selected = try read(fx)
        let duplicate = try MessagesEditTargetResolver.read(databasePath: fx.path, chat: .rowid(3),
            message: .guid("synthetic-other-edit"), partIndex: 0, sandboxPrefix: "apple-cli-test",
            deadline: .millisecondsFromNow(5000))
        #expect(selected.partText == duplicate.partText)
        #expect(selected.messageRowid == 60)
        #expect(duplicate.messageRowid == 61)
        let request = try MessagesEditRequest(snapshot: selected, replacement: "apple-cli-test replacement", sandboxPrefix: "apple-cli-test")
        #expect(try request.matches(selected))
        #expect(try !request.matches(duplicate))
        try fx.exec("DELETE FROM chat_message_join WHERE message_id=60; DELETE FROM message WHERE ROWID=60")
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func workerBaselineBindsParticipantsAlongsideBodyAndIdentity() throws {
        let fx = try fixture()
        let before = try read(fx)
        let request = try MessagesEditRequest(snapshot: before, replacement: "apple-cli-test replacement", sandboxPrefix: "apple-cli-test")
        #expect(try request.matches(before))
        let decoded = try JSONDecoder().decode(MessagesEditRequest.self, from: request.workerPayloadData())
        #expect(try decoded.matches(before))
        try fx.exec("UPDATE handle SET id='+12125550103' WHERE ROWID=1")
        let after = try read(fx)
        #expect(try !decoded.matches(after))
    }

}
