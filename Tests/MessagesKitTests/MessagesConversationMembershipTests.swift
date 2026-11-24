import AppleKit
import Testing
@testable import MessagesKit

struct MessagesConversationMembershipTests {
    private let text = "apple-cli-test membership"

    private func fixture() throws -> ChatFixture {
        let db = try ChatFixture()
        // Preserve stored types so SQLite can compare numeric text against a
        // physical row ID without converting that text to INTEGER on insert.
        try db.exec("""
            ALTER TABLE message ADD COLUMN is_sent INTEGER;
            ALTER TABLE chat_handle_join RENAME TO prior_members;
            CREATE TABLE chat_handle_join(chat_id BLOB, handle_id BLOB);
            INSERT INTO chat_handle_join SELECT * FROM prior_members;
            ALTER TABLE chat_message_join RENAME TO prior_messages;
            CREATE TABLE chat_message_join(chat_id BLOB, message_id BLOB);
            INSERT INTO chat_message_join SELECT * FROM prior_messages;
            ALTER TABLE message_attachment_join RENAME TO prior_attachments;
            CREATE TABLE message_attachment_join(message_id BLOB, attachment_id BLOB);
            INSERT INTO message_attachment_join SELECT * FROM prior_attachments;
            """)
        return db
    }

    private func baseline(_ db: ChatFixture, _ addresses: [String] = ["+12125550100"]) throws -> MessagesConversationBaseline.Snapshot {
        try MessagesConversationBaseline.read(databasePath: db.path, recipients: addresses.map(MessagesConversationAddress.parse),
                                             deadline: .millisecondsFromNow(5000))
    }

    @Test(arguments: [false, true])
    func extraMemberCannotHideDuringPlanning(group: Bool) throws {
        let db = try fixture()
        if group {
            try db.exec("INSERT INTO chat_handle_join VALUES('.1e1',1)")
            #expect(throws: MessagesConversationStore.Failure.invalidObservation) {
                try baseline(db, ["+12125550101", "+12125550102"])
            }
        } else {
            try db.exec("INSERT INTO chat_handle_join VALUES('.3e1',2)")
            #expect(throws: MessagesConversationStore.Failure.invalidObservation) { try baseline(db) }
        }
    }

    @Test(arguments: [
        "INSERT INTO chat_handle_join VALUES('.3e1',2)",
        "INSERT INTO chat_message_join VALUES(3,'6e1')",
        "INSERT INTO chat_message_join VALUES(1,'6e1')",
        "INSERT INTO message_attachment_join VALUES('6e1',10)"
    ])
    func newConflictingEdgePreventsTextOnlyVerification(edge: String) throws {
        let db = try fixture()
        let before = try baseline(db)
        try db.exec("""
            INSERT INTO message(ROWID,guid,text,is_from_me,is_sent,error,service)
            VALUES(60,'synthetic-first','apple-cli-test membership',1,1,0,'iMessage');
            INSERT INTO chat_message_join VALUES(3,60);
            """)
        func observe() throws -> MessagesConversationVerification.Evidence? {
            try MessagesConversationVerification.read(databasePath: db.path, baseline: before, initialText: text,
                                                      deadline: .millisecondsFromNow(5000))
        }
        try db.exec("INSERT INTO message_attachment_join VALUES('9e2',10)")
        #expect(try observe()?.messageRowid == 60)
        try db.exec(edge)
        #expect(throws: (any Error).self) { try observe() }
    }
}
