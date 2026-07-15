import Testing
import Foundation
import SQLite3
@testable import MailKit

/// Hermetic tests against a synthetic Envelope Index fixture (temp SQLite, no real mail, no
/// TCC). Exercises the query builder + dual mailbox-linkage model end-to-end — the logic the
/// live-only paths can't cover in CI.
@Suite("EnvelopeIndex (synthetic fixture)")
struct EnvelopeIndexTests {

    static let iCloudUUID = "AAAA1111-1111-1111-1111-111111111111"
    static let gmailUUID = "BBBB2222-2222-2222-2222-222222222222"

    /// Build a temp Envelope Index with:
    ///  - iCloud INBOX (mbox 1, direct) msgs 10 (flagged/unread, has summary+attachment+recips)
    ///    and 11 (subject-less → LEFT JOIN); iCloud Sent (mbox 2) msg 12 (thread partner of 10).
    ///  - Gmail All Mail (mbox 3, direct home) msg 13, labeled into Gmail INBOX (mbox 4, a label
    ///    with source=3) via the `labels` table.
    static func makeFixture() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-fixture-\(UUID().uuidString).sqlite").path
        var db: OpaquePointer?
        _ = sqlite3_open(path, &db)
        let sql = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INT, unread_count INT, deleted_count INT, source INT);
        INSERT INTO mailboxes VALUES
          (1,'imap://\(iCloudUUID)/INBOX',2,1,0,NULL),
          (2,'imap://\(iCloudUUID)/Sent Messages',1,0,0,NULL),
          (3,'imap://\(gmailUUID)/%5BGmail%5D/All Mail',1,1,0,NULL),
          (4,'imap://\(gmailUUID)/INBOX',1,1,0,3);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        INSERT INTO subjects VALUES (100,'Hello'),(103,'Gmail msg');
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        INSERT INTO addresses VALUES (1000,'alice@x.io','Alice'),(1001,'me@example.com','Me'),(1002,'bob@y.io','Bob');
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        INSERT INTO summaries VALUES (300,'Preview of hello');
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT);
        INSERT INTO message_global_data VALUES (200,'<msg10@host>');
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INT, global_message_id INT,
          subject_prefix TEXT, subject INT, summary INT, sender INT, date_sent INT, date_received INT,
          mailbox INT, flags INT, read INT, flagged INT, deleted INT, size INT, conversation_id INT, flag_color INT);
        INSERT INTO messages VALUES
          (10, 5001, 200, NULL, 100, 300, 1000, 1784000000, 1784000000, 1, 0, 0, 1, 0, 1234, 500, 5),
          (11, 5002, NULL, NULL, 999, NULL, 1000, 1784000100, 1784000100, 1, 0, 1, 0, 0, 10, 501, 0),
          (12, 5003, NULL, NULL, 100, NULL, 1001, 1784000500, 1784000500, 2, 0, 1, 0, 0, 20, 500, 0),
          (13, 5004, NULL, NULL, 103, NULL, 1002, 1784000600, 1784000600, 3, 0, 0, 0, 0, 30, 600, 0);
        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INT, attachment_id TEXT, name TEXT);
        INSERT INTO attachments VALUES (1,10,'1.2','report.pdf');
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INT, address INT, type INT, position INT);
        INSERT INTO recipients VALUES (1,10,1001,0,0),(2,10,1002,1,0);
        CREATE TABLE labels (message_id INT, mailbox_id INT);
        INSERT INTO labels VALUES (13,4);
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        return path
    }

    private func index() throws -> EnvelopeIndex { try EnvelopeIndex(explicitPath: EnvelopeIndexTests.makeFixture()) }

    @Test func loadsMailboxesAndLinkageTypes() throws {
        let idx = try index()
        #expect(idx.mailboxes.count == 4)
        #expect(idx.accountUUIDs().count == 2)
        let gmailInbox = idx.mailboxes.first { $0.url.accountID == Self.gmailUUID && $0.url.leaf == "INBOX" }
        #expect(gmailInbox?.isLabel == true)   // source != nil
        let icloudInbox = idx.mailboxes.first { $0.url.accountID == Self.iCloudUUID && $0.url.leaf == "INBOX" }
        #expect(icloudInbox?.isLabel == false)
    }

    @Test func directMailboxResolutionAndQuery() throws {
        let idx = try index()
        var f = EnvelopeIndex.MessageFilters()
        f.accountUUID = Self.iCloudUUID; f.mailboxName = "INBOX"; f.limit = 50
        let rows = try idx.queryMessages(f)
        #expect(rows.count == 2)                          // msgs 10 + 11
        #expect(try idx.countMessages(f) == 2)
    }

    @Test func subjectlessMessageSurvivesLeftJoin() throws {
        let idx = try index()
        var f = EnvelopeIndex.MessageFilters()
        f.accountUUID = Self.iCloudUUID; f.mailboxName = "INBOX"; f.sortAscending = true
        let msgs = try idx.queryMessages(f).map { MailDecode.message(row: $0, mailboxPath: "INBOX", accountLabel: "iCloud") }
        let subjectless = msgs.first { $0.rowid == 11 }
        #expect(subjectless != nil)                       // NOT dropped by the join
        #expect(subjectless?.subject == "")               // COALESCE empty
    }

    @Test func gmailLabelMembershipViaLabelsTable() throws {
        let idx = try index()
        var f = EnvelopeIndex.MessageFilters()
        f.accountUUID = Self.gmailUUID; f.mailboxName = "INBOX"; f.limit = 50
        let rows = try idx.queryMessages(f)
        #expect(rows.count == 1)                          // msg 13, reached via labels table
        #expect(intVal(rows.first?["rowid"] ?? nil) == 13)
    }

    @Test func mailboxAllCountsEachMessageOnce() throws {
        let idx = try index()
        var f = EnvelopeIndex.MessageFilters()
        f.accountUUID = Self.gmailUUID; f.mailboxName = "All"; f.limit = 50
        // Gmail: All → the source-NULL home store only (msg 13), not the INBOX label dup.
        #expect(try idx.queryMessages(f).count == 1)
    }

    @Test func threadByConversationIDReturnsAllMembers() throws {
        let idx = try index()
        var f = EnvelopeIndex.MessageFilters()
        f.mailboxName = "All"; f.conversationID = 500; f.sortAscending = true; f.limit = 50
        let rows = try idx.queryMessages(f)
        #expect(rows.count == 2)                          // msg 10 (INBOX) + msg 12 (Sent)
        let ids = rows.compactMap { intVal($0["rowid"] ?? nil) }.sorted()
        #expect(ids == [10, 12])
    }

    @Test func recipientsAndAttachmentsDecode() throws {
        let idx = try index()
        let recips = try idx.recipients(messageRowid: 10)
        #expect(recips.to == ["Me <me@example.com>"])
        #expect(recips.cc == ["Bob <bob@y.io>"])
        let atts = try idx.attachments(messageRowid: 10)
        #expect(atts.count == 1)
        #expect(atts.first?.name == "report.pdf")
    }

    @Test func messageByInternetMessageID() throws {
        let idx = try index()
        let row = try idx.message(internetMessageID: "msg10@host")
        #expect(intVal(row?["rowid"] ?? nil) == 10)
        // Full decode carries the union fields.
        let m = MailDecode.message(row: row!, mailboxPath: "INBOX", accountLabel: "iCloud")
        #expect(m.internet_message_id == "msg10@host")
        #expect(m.flagged == true)
        #expect(m.flag_color_name == "purple")
        #expect(m.has_attachments == true)
    }

    @Test func searchFiltersSubjectAndFlagged() throws {
        let idx = try index()
        var f = EnvelopeIndex.MessageFilters()
        f.accountUUID = Self.iCloudUUID; f.mailboxName = "All"; f.subjectContains = "hello"
        // msgs 10 (INBOX) + 12 (Sent) both subject "Hello".
        #expect(try idx.queryMessages(f).count == 2)
        f.flagged = true
        #expect(try idx.queryMessages(f).count == 1)      // only msg 10 is flagged
    }
}
