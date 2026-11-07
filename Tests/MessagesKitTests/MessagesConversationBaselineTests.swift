import AppleKit
import Foundation
import SQLite3
import Testing
@testable import MessagesKit

@Suite("Conversation creation persisted baseline")
struct MessagesConversationBaselineTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        return fx
    }

    private func recipients(_ values: [String] = ["+12125550100"]) throws -> [MessagesConversationAddress] {
        try values.map(MessagesConversationAddress.parse)
    }

    private func read(_ fx: ChatFixture, _ values: [String] = ["+12125550100"]) throws -> MessagesConversationBaseline.Snapshot {
        try MessagesConversationBaseline.read(databasePath: fx.path, recipients: recipients(values),
            deadline: .millisecondsFromNow(5000))
    }

    @Test func bindsUniqueDMAndGlobalWatermarks() throws {
        let fx = try fixture()
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(99,'synthetic-sms',45,'SMS');
            INSERT INTO message(ROWID,guid,service) VALUES(100,'synthetic-high-message','SMS');
            """)
        let baseline = try read(fx)
        #expect(baseline.maximumChatRowid == 99)
        #expect(baseline.maximumMessageRowid == 100)
        try #require(baseline.matchingConversations.count == 1)
        #expect(baseline.matchingConversations[0].rowid == 3)
        #expect(baseline.matchingConversations[0].guid == "iMessage;-;+12125550100")
        #expect(baseline.matchingConversations[0].recipients.map(\.canonical) == ["+12125550100"])
    }

    @Test func absentRecipientDoesNotGuessAnID() throws {
        let fx = try fixture()
        #expect(try read(fx, ["+12125550199"]).matchingConversations.isEmpty)
    }

    @Test func duplicateMatchingDMsRemainAmbiguous() throws {
        let fx = try fixture()
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(10,'synthetic-second-dm',45,'iMessage');
            INSERT INTO chat_handle_join VALUES(10,1);
            """)
        #expect(try read(fx).matchingConversations.map(\.rowid) == [3, 10])
    }

    @Test func matchesCompleteGroupSetWithoutPromisingReuse() throws {
        let fx = try fixture()
        let baseline = try read(fx, ["+12125550102", "+12125550101"])
        #expect(baseline.requestedRecipients.map(\.canonical) == ["+12125550101", "+12125550102"])
        #expect(baseline.matchingConversations.map(\.rowid) == [1])
        #expect(try read(fx, ["+12125550100", "+12125550101"]).matchingConversations.isEmpty)
    }

    @Test func formattingUsesTheSharedAddressIdentity() throws {
        let fx = try fixture()
        try fx.exec("UPDATE handle SET id='+1 (212) 555-0100' WHERE ROWID=1;")
        #expect(try read(fx).matchingConversations.map(\.rowid) == [3])
    }

    @Test(arguments: [
        "INSERT INTO chat_handle_join VALUES(3,1);",
        "UPDATE chat_handle_join SET handle_id=999 WHERE chat_id=3;",
        "UPDATE chat_handle_join SET handle_id=1.5 WHERE chat_id=3;",
        "UPDATE chat_handle_join SET chat_id='3bad' WHERE chat_id=3;",
        "UPDATE handle SET id=X'2b3132313235353530313030' WHERE ROWID=1;",
        "UPDATE handle SET id='+12125550100 ext 42' WHERE ROWID=1;",
        "UPDATE chat SET style=45.5 WHERE ROWID=3;",
        "UPDATE chat SET service_name=X'694d657373616765' WHERE ROWID=3;",
        "UPDATE chat SET guid=X'616263' WHERE ROWID=3;",
        "UPDATE chat SET guid=CAST(X'ff' AS TEXT) WHERE ROWID=3;",
        "UPDATE chat SET guid='' WHERE ROWID=3;",
    ])
    func malformedEvidenceCannotBecomeAbsentOrUnique(_ sql: String) throws {
        let fx = try fixture()
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx) }
    }

    private func addOtherDM(_ fx: ChatFixture, address: String) throws {
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(90,'synthetic-other',45,'iMessage');
            INSERT INTO handle(ROWID,id,service) VALUES(90,'\(address)','iMessage');
            INSERT INTO chat_handle_join VALUES(90,90);
            """)
    }

    @Test func disjointStoredAddressesDoNotHideExactDMs() throws {
        let fx = try fixture()
        try addOtherDM(fx, address: "urn:biz:11111111-2222-3333-4444-555555555555")
        #expect(try read(fx).matchingConversations.map(\.rowid) == [3])
        try fx.exec("ALTER TABLE handle ADD COLUMN country TEXT;")
        try fx.exec("UPDATE handle SET id='5550199',country='us' WHERE ROWID=90;")
        #expect(try read(fx).matchingConversations.map(\.rowid) == [3])
        #expect(try read(fx, ["+12125550198"]).matchingConversations.isEmpty)
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(91,'another-dm',45,'iMessage');
            INSERT INTO chat_handle_join VALUES(91,1);
            """)
        #expect(try read(fx).matchingConversations.map(\.rowid) == [3, 91])
    }

    @Test(arguments: [
        ("5550100", "'US'"), ("5550199", "NULL"), ("5550199", "'XX'"),
        ("5550199", "X'5553'"), ("1550199", "'US'"),
        ("urn:biz:not-a-uuid", "'US'"), ("5550199 ext 8", "'US'"),
    ])
    func unresolvedStoredAddressRefusesEvenWithAnExactDM(_ address: String, _ countrySQL: String) throws {
        let fx = try fixture()
        try addOtherDM(fx, address: address)
        try fx.exec("ALTER TABLE handle ADD COLUMN country TEXT;")
        try fx.exec("UPDATE handle SET country=\(countrySQL) WHERE ROWID=90;")
        #expect(throws: MessagesConversationStore.Failure.invalidObservation) { try read(fx) }
    }

    @Test func missingOrGeneratedCountryCannotDisambiguateLocalNumber() throws {
        let fx = try fixture()
        try addOtherDM(fx, address: "5550199")
        #expect(throws: MessagesConversationStore.Failure.invalidObservation) { try read(fx) }
        try fx.exec("ALTER TABLE handle ADD COLUMN country TEXT GENERATED ALWAYS AS ('US') VIRTUAL;")
        #expect(throws: MessagesConversationStore.Failure.invalidObservation) { try read(fx) }
    }

    @Test func businessHandleCannotMaskDuplicateOrBrokenMembership() throws {
        let fx = try fixture()
        try addOtherDM(fx, address: "urn:biz:11111111-2222-3333-4444-555555555555")
        try fx.exec("INSERT INTO chat_handle_join VALUES(90,90);")
        #expect(throws: MessagesConversationStore.Failure.invalidObservation) { try read(fx) }
        try fx.exec("UPDATE chat_handle_join SET handle_id=999 WHERE chat_id=90;")
        #expect(throws: MessagesConversationStore.Failure.invalidObservation) { try read(fx) }
    }

    @Test func duplicateGUIDOutsideMatchingServiceStillRefusesIdentity() throws {
        let fx = try fixture()
        try fx.exec("INSERT INTO chat(ROWID,guid,style,service_name) VALUES(10,'iMessage;-;+12125550100',45,'SMS');")
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func canonicallyEquivalentGUIDBytesAreDistinct() throws {
        let fx = try fixture()
        try fx.exec("""
            UPDATE chat SET guid=CAST(X'c3a9' AS TEXT) WHERE ROWID=3;
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(10,CAST(X'65cc81' AS TEXT),45,'iMessage');
            INSERT INTO chat_handle_join VALUES(10,1);
            """)
        let result = try read(fx).matchingConversations
        try #require(result.count == 2)
        #expect(!result[0].guid.utf8.elementsEqual(result[1].guid.utf8))
    }

    @Test func emptyMembershipDoesNotIdentifyAnExistingMatch() throws {
        let fx = try fixture()
        try fx.exec("DELETE FROM chat_handle_join WHERE chat_id=3;")
        #expect(try read(fx).matchingConversations.isEmpty)
    }

    @Test(arguments: [
        "ALTER TABLE chat ADD COLUMN _rowid_ INTEGER;",
        "ALTER TABLE message ADD COLUMN _rowid_ INTEGER GENERATED ALWAYS AS (7) VIRTUAL;",
        "ALTER TABLE chat RENAME COLUMN guid TO stored_guid; ALTER TABLE chat ADD COLUMN guid TEXT GENERATED ALWAYS AS (stored_guid) VIRTUAL;",
        "ALTER TABLE message DROP COLUMN is_sent;",
        "DROP TABLE chat_handle_join; CREATE VIEW chat_handle_join AS SELECT 3 AS chat_id,1 AS handle_id;",
    ])
    func unsupportedSchemaRefusesBeforeHandoff(_ sql: String) throws {
        let fx = try fixture()
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func allObservationReadsShareOnePinnedTransaction() throws {
        let fx = try fixture()
        // Keep the WAL owner alive, as Messages does. Closing the last writer
        // can remove WAL sidecars before the read-only connection opens them.
        var writer: OpaquePointer?
        try #require(sqlite3_open(fx.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; SELECT count(*) FROM chat;", nil, nil, nil) == SQLITE_OK)
        let addresses = try recipients()
        try SQLiteReader.withBoundedReadTransaction(path: fx.path,
            limits: .init(timeout: 5, rows: 8192, bytes: 4_194_304, valueBytes: 1_048_576)) { scope in
            let before = try MessagesConversationBaseline.read(in: scope, recipients: addresses)
            try fx.exec("""
                INSERT INTO chat(ROWID,guid,style,service_name) VALUES(90,'synthetic-concurrent-dm',45,'iMessage');
                INSERT INTO chat_handle_join VALUES(90,1);
                INSERT INTO message(ROWID,guid,service) VALUES(100,'synthetic-concurrent-message','iMessage');
                """)
            let pinned = try MessagesConversationBaseline.read(in: scope, recipients: addresses)
            #expect(pinned.maximumChatRowid == before.maximumChatRowid)
            #expect(pinned.maximumMessageRowid == before.maximumMessageRowid)
            #expect(pinned.matchingConversations.map(\.rowid) == [3])
        }
        #expect(try read(fx).matchingConversations.map(\.rowid) == [3, 90])
    }

    @Test func duplicateRequestedRecipientsRefuse() throws {
        let fx = try fixture()
        #expect(throws: (any Error).self) { try read(fx, ["+12125550100", "+1 (212) 555-0100"]) }
    }

    @Test func queryBudgetExhaustionIsNotAbsence() throws {
        let fx = try fixture()
        #expect(throws: (any Error).self) {
            try SQLiteReader.withBoundedReadTransaction(path: fx.path,
                limits: .init(timeout: 5, rows: 1, bytes: 4096, valueBytes: 4096)) { scope in
                try MessagesConversationBaseline.read(in: scope, recipients: recipients())
            }
        }
    }

    @Test func expiryAndCancellationPrecedeDatabaseAccess() throws {
        let addresses = try recipients()
        #expect(throws: WorkerProtocolError.deadlineExpired) {
            try MessagesConversationBaseline.read(databasePath: "/synthetic-missing", recipients: addresses,
                deadline: .millisecondsFromNow(0))
        }
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesConversationBaseline.read(databasePath: "/synthetic-missing", recipients: addresses,
                deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
    }
}
