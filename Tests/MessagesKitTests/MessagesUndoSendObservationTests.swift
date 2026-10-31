import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendObservationTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("""
            ALTER TABLE message ADD COLUMN is_sent INTEGER;
            ALTER TABLE message ADD COLUMN date_edited INTEGER;
            ALTER TABLE message ADD COLUMN date_retracted INTEGER;
            ALTER TABLE message ADD COLUMN message_summary_info BLOB;
            UPDATE message SET is_sent=1,date_edited=0,date_retracted=0,
                message_summary_info=X'0102' WHERE ROWID=2;
            """)
        return fx
    }

    private func read(_ fx: ChatFixture) throws -> MessagesUndoSendObservation.Snapshot {
        try MessagesUndoSendObservation.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(2),
                                              deadline: .millisecondsFromNow(5000))
    }

    @Test func recordsTypedStatusAndRawBytes() throws {
        let fx = try fixture()
        let value = try read(fx)
        #expect(value.identity.messageGUID == "g2")
        #expect(value.isFromMe == .value(1))
        #expect(value.isSent == .value(1))
        #expect(value.error == .value(0))
        #expect(value.dateEdited == .value(0))
        #expect(value.dateRetracted == .value(0))
        #expect(value.serviceUTF8 == .value(Data("iMessage".utf8)))
        #expect(value.textUTF8 == .value(Data("my reply".utf8)))
        #expect(value.attributedBody == .null)
        #expect(value.summaryInfo == .value(Data([1, 2])))
    }

    @Test func nullAndWrongTypeDoNotBecomeZero() throws {
        let fx = try fixture()
        try fx.exec("UPDATE message SET is_from_me=NULL,is_sent=1.5,error='bad',date_retracted=NULL WHERE ROWID=2")
        let value = try read(fx)
        #expect(value.isFromMe == .null)
        #expect(value.isSent == .wrongType)
        #expect(value.error == .wrongType)
        #expect(value.dateRetracted == .null)
    }

    @Test func absentBodyAndObservedRetractionRemainSeparate() throws {
        let fx = try fixture()
        let before = try read(fx)
        try fx.exec("UPDATE message SET text=NULL,attributedBody=NULL,date_retracted=123 WHERE ROWID=2")
        let after = try read(fx)
        #expect(before.identity.matches(after.identity))
        #expect(after.textUTF8 == .null)
        #expect(after.attributedBody == .null)
        #expect(after.dateRetracted == .value(123))
        // Raw markers are observations, not a successful retraction verdict.
    }

    @Test func emptyBlobNullAndWrongStorageRemainDistinct() throws {
        let fx = try fixture()
        try fx.exec("UPDATE message SET attributedBody=X'',message_summary_info=NULL,service=X'694D657373616765' WHERE ROWID=2")
        let value = try read(fx)
        #expect(value.attributedBody == .value(Data()))
        #expect(value.summaryInfo == .null)
        #expect(value.serviceUTF8 == .wrongType)
    }

    @Test func retainsInvalidUTF8WithoutReplacementCharacters() throws {
        let fx = try fixture()
        try fx.exec("UPDATE message SET text=CAST(X'FF' AS TEXT) WHERE ROWID=2")
        #expect(try read(fx).textUTF8 == .value(Data([255])))
    }

    @Test func wrongTypeLargeValuesAreNotMaterialized() throws {
        let fx = try fixture()
        try fx.exec("UPDATE message SET is_from_me=zeroblob(2097152),message_summary_info=CAST(zeroblob(2097152) AS TEXT) WHERE ROWID=2")
        let value = try read(fx)
        #expect(value.isFromMe == .wrongType)
        #expect(value.summaryInfo == .wrongType)
    }

    @Test func correctBlobOverLimitFailsRatherThanBecomingAbsent() throws {
        let fx = try fixture()
        try fx.exec("UPDATE message SET attributedBody=zeroblob(1048577) WHERE ROWID=2")
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func missingSchemaOrMembershipCannotYieldObservation() throws {
        let missingSchema = try ChatFixture()
        #expect(throws: MessagesUndoSendObservation.Failure.unsupportedSchema) { try read(missingSchema) }
        let fx = try fixture()
        try fx.exec("DELETE FROM chat_message_join WHERE message_id=2")
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func cancelledObservationRefusesBeforeDatabaseOpen() throws {
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendObservation.read(databasePath: "/not-a-database", chat: .rowid(3), message: .rowid(2),
                deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
    }
}
