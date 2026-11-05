import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite("Conversation creation persisted verification")
struct MessagesConversationVerificationTests {
    private let text = "apple-cli-test creation"

    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        return fx
    }

    private func baseline(_ fx: ChatFixture, _ recipients: [String] = ["+12125550100"]) throws -> MessagesConversationBaseline.Snapshot {
        try MessagesConversationBaseline.read(databasePath: fx.path,
            recipients: recipients.map(MessagesConversationAddress.parse), deadline: .millisecondsFromNow(5000))
    }

    private func send(_ fx: ChatFixture, id: Int = 60, chat: Int = 3) throws {
        try fx.exec("""
            INSERT INTO message(ROWID,guid,text,is_from_me,is_sent,error,service)
            VALUES(\(id),'synthetic-create-\(id)','apple-cli-test creation',1,1,0,'iMessage');
            INSERT INTO chat_message_join VALUES(\(chat),\(id));
            """)
    }

    private func read(_ fx: ChatFixture, _ before: MessagesConversationBaseline.Snapshot,
                      text: String? = nil) throws -> MessagesConversationVerification.Evidence? {
        try MessagesConversationVerification.read(databasePath: fx.path, baseline: before,
            initialText: text ?? self.text, deadline: .millisecondsFromNow(5000))
    }

    @Test func exactExistingDMReturnsObservedIdentity() throws {
        let fx = try fixture(), before = try baseline(fx)
        try send(fx)
        let result = try #require(try read(fx, before))
        #expect(result.messageRowid == 60)
        #expect(result.messageGUID == "synthetic-create-60")
        #expect(result.conversation.rowid == 3)
        #expect(result.observation == .presentAtBaseline)
        #expect(result.creationAttribution == "unproven")
    }

    @Test func newConversationIsObservedWithoutCausalAttribution() throws {
        let fx = try fixture(), before = try baseline(fx, ["+12125550101"])
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(70,'synthetic-new-dm',45,'iMessage');
            INSERT INTO chat_handle_join VALUES(70,2);
            """)
        try send(fx, chat: 70)
        let result = try #require(try read(fx, before))
        #expect(result.conversation.rowid == 70)
        #expect(result.observation == .firstObservedAfterBaseline)
        #expect(result.creationAttribution == "unproven")
    }

    @Test func completeIdentityWithUnknownProvenanceRemainsExplicit() throws {
        let fx = try fixture(), before = try baseline(fx, ["+12125550101", "+12125550100"])
        try fx.exec("INSERT INTO chat_handle_join VALUES(2,1),(2,2);")
        try send(fx, chat: 2)
        let result = try #require(try read(fx, before))
        #expect(result.observation == .unestablished)
        #expect(result.creationAttribution == "unproven")
    }

    @Test func existingGroupReportsActualIdentityWithoutForcingReuse() throws {
        let fx = try fixture(), before = try baseline(fx, ["+12125550101", "+12125550102"])
        try send(fx, chat: 1)
        #expect(try read(fx, before)?.observation == .presentAtBaseline)
    }

    @Test func identicalConcurrentSendsNeverPickNewest() throws {
        let fx = try fixture(), before = try baseline(fx)
        try send(fx); try send(fx, id: 61)
        #expect(throws: MessagesConversationVerification.Failure.ambiguous) { try read(fx, before) }
    }

    @Test func noNewMessageAndReusedRowidCannotMatchOldText() throws {
        let fx = try fixture()
        try send(fx)
        let before = try baseline(fx)
        #expect(try read(fx, before) == nil)
        try fx.exec("DELETE FROM message WHERE ROWID=60; DELETE FROM chat_message_join WHERE message_id=60;")
        try send(fx)
        #expect(try read(fx, before) == nil)
    }

    @Test func uniqueBaselineDMCannotSilentlySwitchConversation() throws {
        let fx = try fixture(), before = try baseline(fx)
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(70,'synthetic-other-dm',45,'iMessage');
            INSERT INTO chat_handle_join VALUES(70,1);
            """)
        try send(fx, chat: 70)
        #expect(throws: (any Error).self) { try read(fx, before) }
    }

    @Test(arguments: [
        "INSERT INTO chat_message_join VALUES(3,60);",
        "INSERT INTO chat_message_join VALUES(1,60);",
        "DELETE FROM chat_message_join WHERE message_id=60;",
        "UPDATE chat_message_join SET chat_id='3bad' WHERE message_id=60;",
        "UPDATE chat_message_join SET message_id='60bad' WHERE message_id=60;",
        "INSERT INTO chat_handle_join VALUES(3,1);",
        "UPDATE chat_handle_join SET handle_id=999 WHERE chat_id=3;",
        "UPDATE message SET is_sent=NULL WHERE ROWID=60;",
        "UPDATE message SET is_sent=0 WHERE ROWID=60;",
        "UPDATE message SET error=1 WHERE ROWID=60;",
        "UPDATE message SET text=X'616263' WHERE ROWID=60;",
        "UPDATE message SET text=CAST(X'ff' AS TEXT) WHERE ROWID=60;",
        "UPDATE message SET attributedBody=X'0000' WHERE ROWID=60;",
        "UPDATE message SET guid=X'616263' WHERE ROWID=60;",
        "UPDATE message SET guid='' WHERE ROWID=60;",
        "UPDATE message SET guid='g1' WHERE ROWID=60;",
        "UPDATE chat SET guid='synthetic-replaced' WHERE ROWID=3;",
        "INSERT INTO message_attachment_join VALUES(60,10);",
    ])
    func incompleteOrConflictingEvidenceCannotSucceed(_ sql: String) throws {
        let fx = try fixture(), before = try baseline(fx)
        try send(fx); try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx, before) }
    }

    @Test(arguments: [
        "UPDATE message SET is_from_me=0 WHERE ROWID=60;",
        "UPDATE message SET service='SMS' WHERE ROWID=60;",
        "UPDATE message SET text='different text' WHERE ROWID=60;",
        "UPDATE chat_message_join SET chat_id=1 WHERE message_id=60;",
    ])
    func knownNonmatchesDoNotBecomeSuccess(_ sql: String) throws {
        let fx = try fixture(), before = try baseline(fx)
        try send(fx); try fx.exec(sql)
        #expect(try read(fx, before) == nil)
    }

    @Test func strictAttributedBodySuppliesMissingText() throws {
        let fx = try fixture(), before = try baseline(fx)
        try send(fx)
        let body = NSMutableAttributedString(string: text)
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0),
            range: NSRange(location: 0, length: body.length))
        let hex = NSArchiver.archivedData(withRootObject: body).map { String(format: "%02x", $0) }.joined()
        try fx.exec("UPDATE message SET text=NULL,attributedBody=X'\(hex)' WHERE ROWID=60;")
        #expect(try read(fx, before)?.messageRowid == 60)
        try fx.exec("UPDATE message SET text='conflicting' WHERE ROWID=60;")
        #expect(throws: (any Error).self) { try read(fx, before) }
    }

    @Test func textComparisonUsesBytesNotUnicodeCanonicalEquality() throws {
        let fx = try fixture(), before = try baseline(fx)
        try send(fx)
        try fx.exec("UPDATE message SET text=CAST(X'65cc81' AS TEXT) WHERE ROWID=60;")
        #expect(try read(fx, before, text: "é") == nil)
    }

    @Test func exhaustedCandidateBudgetNeverMeansUnique() throws {
        let fx = try fixture(), before = try baseline(fx)
        try send(fx)
        try fx.exec("""
            WITH RECURSIVE n(x) AS (VALUES(100) UNION ALL SELECT x+1 FROM n WHERE x<611)
            INSERT INTO message(ROWID,guid,text,is_from_me,is_sent,error,service)
            SELECT x,'synthetic-unrelated-'||x,'different',0,1,0,'iMessage' FROM n;
            """)
        #expect(throws: (any Error).self) { try read(fx, before) }
    }

    @Test func cancellationAndDeadlinePrecedeRead() throws {
        let fx = try fixture(), before = try baseline(fx)
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesConversationVerification.read(databasePath: "/synthetic-missing", baseline: before,
                initialText: text, deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
        #expect(throws: WorkerProtocolError.deadlineExpired) {
            try MessagesConversationVerification.read(databasePath: "/synthetic-missing", baseline: before,
                initialText: text, deadline: .millisecondsFromNow(0))
        }
    }

    @Test func attachmentSchemaIsRequiredBeforeHandoff() throws {
        let fx = try fixture()
        try fx.exec("DROP TABLE message_attachment_join;")
        #expect(throws: (any Error).self) { try baseline(fx) }
    }
}
