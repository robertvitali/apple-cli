import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct MessagesAttachmentSnapshotTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(1,10)")
        return fx
    }

    private func read(_ fx: ChatFixture, messageRowid: Int64 = 1, cancelled: @escaping () -> Bool = { false }) throws -> [MessagesAttachmentSnapshot.Item] {
        try SQLiteReader.withBoundedReadTransaction(path: fx.path,
            limits: .init(timeout: 5, rows: 2_048, bytes: 16 * 1_024 * 1_024, valueBytes: 65_536), isCancelled: cancelled) {
                try MessagesAttachmentSnapshot.read(in: $0, messageRowid: messageRowid)
            }
    }

    @Test func completeSnapshotFeedsActualFileVerification() throws {
        let fx = try fixture()
        try fx.exec("ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state=5")
        let items = try read(fx)
        #expect(!items.isEmpty)
        let probe = MessagesAttachmentFileInspection(homeDirectory: fx.homePath)
        let observations = try items.map {
            MessagesAttachmentRetrievalState.Observation(identity: $0.identity, transfer: $0.transfer,
                                                          file: try probe.inspect(filename: $0.filename))
        }
        // Fixture message 1 has a real, confined attachment.
        #expect(MessagesAttachmentRetrievalState.evaluate(expected: items.map(\.identity), observed: observations, completeJoin: true) == .downloaded)
    }

    @Test func danglingAndDuplicateMembershipAreRejected() throws {
        let orphan = try fixture()
        try orphan.exec("INSERT INTO message_attachment_join VALUES(1,999999)")
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) { try read(orphan) }
        let duplicate = try fixture()
        try duplicate.exec("INSERT INTO message_attachment_join SELECT message_id,attachment_id FROM message_attachment_join WHERE message_id=1")
        #expect(throws: MessagesAttachmentSnapshot.Failure.duplicateIdentity) { try read(duplicate) }
    }

    @Test(arguments: ["X'31'", "'1bad'", "1.25"])
    func malformedMessageEdgeCannotDisappearFromMembership(_ storedID: String) throws {
        let fx = try fixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(\(storedID),999999)")
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) { try read(fx) }
    }

    @Test(arguments: ["", "INTEGER", "NUMERIC", "TEXT", "REAL", "BLOB"], ["BINARY", "NOCASE", "RTRIM"])
    func equivalentMembershipSurvivesIndexedAffinityAndCollation(_ affinity: String, _ collation: String) throws {
        let fx = try fixture()
        try fx.exec("""
            ALTER TABLE message_attachment_join RENAME TO old_attachment_edges;
            CREATE TABLE message_attachment_join(message_id \(affinity) COLLATE \(collation), attachment_id INTEGER);
            CREATE INDEX attachment_edges_by_message ON message_attachment_join(message_id);
            INSERT INTO message_attachment_join VALUES('1e2',999999),(9007199254740992,999999);
            """)
        // Exponent notation can satisfy numeric equality without the integer cast matching.
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) { try read(fx, messageRowid: 100) }
        #expect(try read(fx, messageRowid: 101).isEmpty)
        // Adjacent Int64 targets must remain distinct at the Double precision boundary.
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) {
            try read(fx, messageRowid: 9_007_199_254_740_992)
        }
        #expect(try read(fx, messageRowid: 9_007_199_254_740_993).isEmpty)
    }

    @Test func saturatedRealCannotHideFromMaximumRowid() throws {
        let fx = try fixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(9223372036854775807,10),(1e100,999999)")
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) { try read(fx, messageRowid: .max) }
    }

    @Test func unrelatedMalformedEdgesAndUnusedGeneratedColumnsAreIgnored() throws {
        let fx = try fixture()
        try fx.exec("""
            ALTER TABLE attachment ADD COLUMN display_code TEXT GENERATED ALWAYS AS ('unused') VIRTUAL;
            INSERT INTO message_attachment_join VALUES('2bad',999999),(2.25,999999),(X'32',999999);
            """)
        #expect(try read(fx).map(\.identity.rowid) == [10])
    }

    @Test(arguments: ["VIRTUAL", "STORED"])
    func generatedTransferStateCannotProveDownload(_ storage: String) throws {
        let fx = try fixture()
        try fx.exec("""
            ALTER TABLE attachment RENAME TO original_attachment;
            CREATE TABLE attachment(guid TEXT, raw_state INTEGER,
                transfer_state INTEGER GENERATED ALWAYS AS (raw_state) \(storage));
            INSERT INTO attachment(rowid,guid,raw_state) VALUES(10,'a10',5);
            """)
        #expect(throws: MessagesAttachmentSnapshot.Failure.unsupportedSchema) { try read(fx) }
    }

    @Test func optionalSchemaAndMalformedNativeStateStayUnavailable() throws {
        let fx = try fixture()
        let missing = try #require(read(fx).first)
        #expect(missing.transfer.status == "missing-schema")
        try fx.exec("ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state='5'")
        let malformed = try #require(read(fx).first)
        #expect(malformed.transfer.status == "wrong-type")
        #expect(malformed.transfer.raw == nil)
        #expect(throws: SQLiteReadTransaction.Failure.cancelled) { try read(fx, cancelled: { true }) }
    }

    @Test func malformedEdgeStorageAndGuidDoNotCoerce() throws {
        let fx = try fixture()
        try fx.exec("""
            ALTER TABLE message_attachment_join RENAME TO original_message_attachment_join;
            CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id);
            INSERT INTO message_attachment_join SELECT message_id,attachment_id FROM original_message_attachment_join;
            INSERT INTO message_attachment_join VALUES(1,10.0);
            """)
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) { try read(fx) }
        let guid = try fixture()
        try guid.exec("UPDATE attachment SET guid=CAST(X'ff' AS TEXT)")
        #expect(throws: SQLiteReadTransaction.Failure.invalidText) { try read(guid) }
    }
}
