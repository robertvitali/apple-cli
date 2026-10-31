import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendIdentityTests {
    private func read(_ fx: ChatFixture, chat: ChatDB.ExactChatSelector = .rowid(3),
                      message: ChatDB.ExactMessageSelector = .rowid(2)) throws -> MessagesUndoSendIdentity.Snapshot {
        try MessagesUndoSendIdentity.read(databasePath: fx.path, chat: chat, message: message,
                                          deadline: .millisecondsFromNow(5000))
    }

    @Test func preservesChosenMembershipAndBothSelectorForms() throws {
        let fx = try ChatFixture()
        try fx.exec("INSERT INTO chat_message_join VALUES(1,2)")
        let byID = try read(fx)
        let byGUID = try read(fx, chat: .guid("iMessage;-;+12125550100"), message: .guid("g2"))
        #expect(byID.matches(byGUID))
        #expect(byID.chatRowid == 3)
        #expect(byID.messageRowid == 2)
        #expect(byID.sentDateRaw == fx.base - 100)
        #expect(byID.participantHandles == ["+12125550100"])
        #expect(try !byID.matches(read(fx, chat: .rowid(1))))
    }

    @Test func disappearingBodyDoesNotDiscardIdentity() throws {
        let fx = try ChatFixture()
        let before = try read(fx)
        try fx.exec("UPDATE message SET text=NULL, attributedBody=NULL WHERE ROWID=2")
        #expect(try before.matches(read(fx)))
        // The identity result deliberately has no retracted/success Boolean.
    }

    @Test(arguments: [
        "INSERT INTO chat_message_join VALUES(3,2)",
        "INSERT INTO message(ROWID,guid,date) VALUES(60,'g2',1)",
        "INSERT INTO chat(ROWID,guid,style) VALUES(60,'iMessage;-;+12125550100',45)",
        "DELETE FROM chat_message_join WHERE message_id=2",
        "DELETE FROM message WHERE ROWID=2",
        "UPDATE chat SET style=1 WHERE ROWID=3",
        "UPDATE message SET date=0 WHERE ROWID=2",
        "UPDATE message SET date=1.5 WHERE ROWID=2",
        "UPDATE message SET guid=CAST(X'FF' AS TEXT) WHERE ROWID=2",
        "UPDATE message SET guid=CAST(X'610062' AS TEXT) WHERE ROWID=2",
        "UPDATE message SET guid=X'6732' WHERE ROWID=2",
        "UPDATE chat_message_join SET chat_id='3junk' WHERE message_id=2",
        "INSERT INTO chat_handle_join VALUES(3,1)",
        "INSERT INTO chat_handle_join VALUES(3,999)",
        "DELETE FROM chat_handle_join WHERE chat_id=3",
        "UPDATE handle SET id='' WHERE ROWID=1",
        "UPDATE handle SET id=CAST(X'FF' AS TEXT) WHERE ROWID=1",
        "ALTER TABLE message ADD COLUMN _rowid_ INTEGER"
    ]) func refusesAmbiguousMalformedOrMissingIdentity(sql: String) throws {
        let fx = try ChatFixture()
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func rejectsOversizedIdentityAndParticipants() throws {
        let fx = try ChatFixture()
        try fx.exec("UPDATE message SET guid=printf('%0513d',1) WHERE ROWID=2")
        #expect(throws: (any Error).self) { try read(fx) }
        let crowded = try ChatFixture()
        for id in 100...131 {
            try crowded.exec("INSERT INTO handle(ROWID,id) VALUES(\(id),'participant-\(id)@example.com'); INSERT INTO chat_handle_join VALUES(3,\(id))")
        }
        #expect(throws: (any Error).self) { try read(crowded) }
    }

    @Test func canonicalUnicodeEqualityCannotHideGUIDDrift() throws {
        let fx = try ChatFixture()
        try fx.exec("UPDATE message SET guid='caf\u{00E9}' WHERE ROWID=2")
        let before = try read(fx)
        try fx.exec("UPDATE message SET guid='cafe\u{0301}' WHERE ROWID=2")
        let after = try read(fx)
        #expect(before.messageGUID == after.messageGUID)
        #expect(!before.matches(after))
        #expect(throws: (any Error).self) { try read(fx, message: .guid("caf\u{00E9}")) }
        #expect(try after.matches(read(fx, message: .guid("cafe\u{0301}"))))
    }

    @Test func matchesBindsParticipantBytesAndDate() throws {
        let fx = try ChatFixture()
        let before = try read(fx)
        try fx.exec("UPDATE handle SET id='+12125550103' WHERE ROWID=1")
        #expect(try !before.matches(read(fx)))
        let changedParticipant = try read(fx)
        try fx.exec("UPDATE message SET date=date+1 WHERE ROWID=2")
        #expect(try !changedParticipant.matches(read(fx)))
    }

    @Test func cancellationAndInvalidSelectorsFailBeforeReading() throws {
        let fx = try ChatFixture()
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendIdentity.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(2),
                deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
        #expect(throws: (any Error).self) { try read(fx, chat: .rowid(0)) }
        #expect(throws: (any Error).self) { try read(fx, message: .guid("")) }
    }
}
