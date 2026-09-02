import Testing
import Foundation
import SQLite3
@testable import MailKit
import TestSupport

/// Hermetic tests against a synthetic Envelope Index fixture (temp SQLite, no real mail, no
/// TCC). Exercises the query builder + dual mailbox-linkage model end-to-end — the logic the
/// live-only paths can't cover in CI.
@Suite("EnvelopeIndex (synthetic fixture)")
struct EnvelopeIndexTests {

    private let scratch = ScratchDirs("envelope-index")

    static let iCloudUUID = "AAAA1111-1111-1111-1111-111111111111"
    static let gmailUUID = "BBBB2222-2222-2222-2222-222222222222"

    /// Build a temp Envelope Index with:
    ///  - iCloud INBOX (mbox 1, direct) msgs 10 (flagged/unread, has summary+attachment+recips)
    ///    and 11 (subject-less → LEFT JOIN); iCloud Sent (mbox 2) msg 12 (thread partner of 10).
    ///  - Gmail All Mail (mbox 3, direct home) msg 13, labeled into Gmail INBOX (mbox 4, a label
    ///    with source=3) via the `labels` table.
    /// `directory` comes from a suite-held `ScratchDirs`, which reclaims the whole tree (fixture,
    /// `-wal`, `-shm`) when the test instance is released. Callers therefore need no `defer`.
    static func makeFixture(in directory: URL) -> String {
        let path = directory.appendingPathComponent("apple-cli-fixture-\(UUID().uuidString).sqlite").path
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
        INSERT INTO addresses VALUES (1000,'alice@example.com','Alice'),(1001,'me@example.com','Me'),(1002,'bob@example.org','Bob');
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
        CREATE TABLE message_references (ROWID INTEGER PRIMARY KEY, message INT, reference INT, is_originator INT);
        INSERT INTO message_references VALUES
          (1,10,7010,1),(2,10,9000,0),
          (3,12,7012,1),(4,12,9000,0),
          (5,13,7013,1);
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        return path
    }

    /// `EnvelopeIndex` opens with `copyToTemp: true`, so the fixture is genuinely unneeded once
    /// `init` returns. Without cleanup the suite leaked one file per test invocation into `$TMPDIR`:
    /// 979 files, ~42 MB, on the machine where this was found. Poor form in any suite, and worse in
    /// the one repo whose current work is "we leak private data into `$TMPDIR`". `ScratchDirs` now
    /// owns the reclaim, so no `defer` here can be forgotten.
    private func index() throws -> EnvelopeIndex {
        return try EnvelopeIndex(explicitPath: EnvelopeIndexTests.makeFixture(in: try scratch.directory()))
    }

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
        #expect(recips.cc == ["Bob <bob@example.org>"])
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

    // References/In-Reply-To threading (MCP A get_thread): msgs 10 & 12 share reference 9000, msg 13
    // is on its own chain. referencesThread groups by the shared message_references chain, distinct
    // from conversation_id grouping.
    @Test func referencesThreadGroupsBySharedChain() throws {
        let idx = try index()
        let thread10 = try idx.referencesThread(rowid: 10, limit: 50)
        let ids10 = Set(thread10.compactMap { $0["rowid"].flatMap { $0 }.flatMap { Int($0) } })
        #expect(ids10 == [10, 12])                        // both share reference 9000
        let thread13 = try idx.referencesThread(rowid: 13, limit: 50)
        #expect(thread13.count == 1)                      // msg 13's chain (7013) is its own
        let noRefs = try idx.referencesThread(rowid: 11, limit: 50)
        #expect(noRefs.isEmpty)                           // msg 11 has no message_references rows
    }

    // subject_keywords OR-match (MCP B): the union clause matches ANY keyword, ANDs with other
    // filters, and drops empty keywords (never "match all"). Locks the OR semantics so an OR→AND
    // regression or a dropped bind fails CI (the singular path above never exercised the OR clause).
    @Test func subjectKeywordsOrMatch() throws {
        let idx = try index()
        var f = EnvelopeIndex.MessageFilters()
        f.mailboxName = "All"; f.subjectContainsAny = ["hello", "gmail"]
        // "Hello" (msgs 10 iCloud-INBOX, 12 iCloud-Sent) ∪ "Gmail msg" (msg 13 Gmail home store) = 3.
        #expect(try idx.queryMessages(f).count == 3)
        // AND-across-filters still holds: only msg 10 is flagged.
        f.flagged = true
        #expect(try idx.queryMessages(f).count == 1)
        // an empty keyword is DROPPED (not treated as match-all): only "gmail" applies → msg 13.
        f.flagged = nil; f.subjectContainsAny = ["", "gmail"]
        #expect(try idx.queryMessages(f).count == 1)
        // subjectContainsAny takes precedence over the legacy single subjectContains.
        f.subjectContainsAny = ["gmail"]; f.subjectContains = "hello"
        #expect(try idx.queryMessages(f).count == 1)      // "gmail" wins → msg 13, not "hello"
    }
}
