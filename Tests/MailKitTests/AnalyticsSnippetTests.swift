import Testing
import Foundation
import SQLite3
@testable import MailKit

/// The `summaries` join that feeds `Analytics.hasQuestion`'s body test (COMPLETION-LOOP Q4e).
///
/// Oracle B decides "contains a question" from the subject OR the first 500 characters of the
/// message content. `analyticsRows` never selected any body text, so `Row.snippet` was nil for
/// every row and the body half of that test was dead code — `"MEDIUM (contains question)"` could
/// not fire on a body-only question, and `priorityScore` permanently lost its 2-point body term.
///
/// These tests own their fixtures. The shared `EnvelopeIndexTests.makeFixture()` is deliberately
/// not reused: one of them must build a store with NO `summaries` table, which is a different
/// schema rather than different data.
@Suite("Analytics snippet sourcing")
struct AnalyticsSnippetTests {

    static let acct = "AAAAAAAA-1111-2222-3333-444444444444"

    /// A minimal Envelope Index.
    ///
    /// `table` and `column` are INDEPENDENT because `summariesAvailable` is a conjunction of two
    /// checks, and a fixture that drops both at once cannot tell them apart: deleting the column
    /// check entirely still passed, because the degrade fixture had no table either. The mixed
    /// schema (`table: true, column: false`) is the one the second conjunct exists for — on it a
    /// hard-coded join throws `no such column: m.summary`.
    static func fixture(table: Bool, column: Bool) -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-snipfx-\(UUID().uuidString).sqlite").path
        var db: OpaquePointer?
        _ = sqlite3_open(path, &db)
        var sql = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INT, unread_count INT, deleted_count INT, source INT);
        INSERT INTO mailboxes VALUES (1,'imap://\(acct)/INBOX',3,0,0,NULL);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        INSERT INTO subjects VALUES (100,'Quiet subject'),(101,'Does this work?');
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        INSERT INTO addresses VALUES (1000,'alice@x.io','Alice');
        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INT, attachment_id TEXT, name TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject_prefix TEXT, subject INT, \(column ? "summary INT," : "")
          sender INT, date_sent INT, date_received INT, mailbox INT, read INT, flagged INT, deleted INT);

        """
        if table {
            sql += """
            CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
            INSERT INTO summaries VALUES
              (300,'A perfectly flat preview with no punctuation of interest'),
              (301,'Hi Jane, could you take a look at this? Thanks.');

            """
        }
        sql += column
            ? """
              INSERT INTO messages VALUES
                (10,NULL,100,300,1000,1784000000,1784000000,1,1,0,0),
                (11,NULL,100,301,1000,1784000100,1784000100,1,1,0,0),
                (12,NULL,101,NULL,1000,1784000200,1784000200,1,1,0,0);
              """
            : """
              INSERT INTO messages VALUES
                (10,NULL,100,1000,1784000000,1784000000,1,1,0,0),
                (11,NULL,100,1000,1784000100,1784000100,1,1,0,0),
                (12,NULL,101,1000,1784000200,1784000200,1,1,0,0);
              """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        return path
    }

    static func index(table: Bool, column: Bool) throws -> EnvelopeIndex {
        let p = fixture(table: table, column: column)
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + s) } }
        return try EnvelopeIndex(explicitPath: p)
    }

    func rowsByID(_ idx: EnvelopeIndex) throws -> [Int: [String: String?]] {
        var out: [Int: [String: String?]] = [:]
        for r in try idx.analyticsRows(accountUUID: Self.acct, mailboxName: "INBOX", sinceUnix: nil) {
            if let s = r["rowid"] ?? nil, let n = Int(s) { out[n] = r }
        }
        return out
    }

    @Test("analyticsRows sources snippet from the summaries table")
    func joinsSummaries() throws {
        let rows = try rowsByID(Self.index(table: true, column: true))
        #expect(rows.count == 3, "control: all three messages are returned")

        // Without the join every one of these is nil — which is precisely the shipped bug.
        #expect((rows[10]?["snippet"] ?? nil) == "A perfectly flat preview with no punctuation of interest")
        #expect((rows[11]?["snippet"] ?? nil) == "Hi Jane, could you take a look at this? Thanks.")
        #expect((rows[12]?["snippet"] ?? nil) == nil, "a message with no summary FK has no snippet")
    }

    @Test("a body-only question now scores as a question, as the oracle scores it")
    func bodyOnlyQuestionIsSeen() throws {
        let rows = try rowsByID(Self.index(table: true, column: true))

        func row(_ id: Int) throws -> Analytics.Row {
            let r = try #require(rows[id])
            return Analytics.Row(rowid: id, senderAddress: "alice@x.io", senderName: "Alice",
                                 subject: (r["subject"] ?? nil) ?? "", dateReceived: nil,
                                 read: true, flagged: false, hasAttachment: false, mailboxRowid: 1,
                                 snippet: r["snippet"] ?? nil)
        }

        // 11: no "?" in the subject, "?" in the body. This is the case that could not fire before.
        let bodyOnly = try row(11)
        #expect(!bodyOnly.subject.contains("?"), "control: the subject really has no question mark")
        #expect(Analytics.hasQuestion(bodyOnly))
        #expect(Analytics.priorityLabel(flagged: false, hasQuestion: Analytics.hasQuestion(bodyOnly))
                == "MEDIUM (contains question)")

        // 10: neither subject nor body — must stay negative, or the test above proves nothing.
        #expect(!Analytics.hasQuestion(try row(10)), "a flat message must not be scored as a question")
        // 12: subject-only question still works, i.e. the join did not displace the subject test.
        #expect(Analytics.hasQuestion(try row(12)))
    }

    @Test("a store with no summaries table still works, it just has no snippets")
    func degradesWithoutSummariesTable() throws {
        // The reason `summariesAvailable` is probed rather than assumed: the Envelope Index schema
        // is Apple's private format and varies by Mail version. A hard-coded join turns every
        // analytics query into an error here — a far worse outcome than the weaker question
        // detection the join exists to improve.
        let rows = try rowsByID(Self.index(table: false, column: false))
        #expect(rows.count == 3, "the query must still succeed and return every message")
        #expect((rows[10]?["snippet"] ?? nil) == nil)
        #expect((rows[12]?["subject"] ?? nil) == "Does this work?", "and the rest of the row is intact")
        // The subject test is unaffected by the absence of body text.
        let r = try #require(rows[12])
        #expect(Analytics.hasQuestion(Analytics.Row(
            rowid: 12, senderAddress: nil, senderName: nil, subject: (r["subject"] ?? nil) ?? "",
            dateReceived: nil, read: true, flagged: false, hasAttachment: false, mailboxRowid: 1,
            snippet: nil)))
    }

    @Test("a store with the summaries table but no messages.summary column also degrades")
    func degradesWithoutSummaryColumn() throws {
        // The probe is a CONJUNCTION — table present AND column present — and this is the arm that
        // distinguishes the second half. Review caught that deleting the column check entirely left
        // the suite green, because the other degrade fixture has no table either. On this schema a
        // hard-coded join throws `no such column: m.summary`.
        let rows = try rowsByID(Self.index(table: true, column: false))
        #expect(rows.count == 3, "the query must still succeed on a mixed schema")
        #expect((rows[10]?["snippet"] ?? nil) == nil, "and simply carry no snippet")
    }

    @Test("only the first 500 characters of the preview are consulted, as the oracle does")
    func honoursThe500CharacterWindow() throws {
        // The 500-char bound is the parity-relevant part of this change and had no test at all.
        // The oracle truncates with `text 1 thru 500 of msgContent` before looking for "?", so a
        // question mark past that point must not register.
        //
        // There are TWO truncations and this asserts both SEPARATELY, because with `SUBSTR` in
        // place the snippet reaching Swift is already 500 chars, so `.prefix(500)` is unreachable
        // through the query and an earlier version of this test silently covered only the SQL half.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-snipfx-\(UUID().uuidString).sqlite").path
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + x) } }
        var db: OpaquePointer?
        _ = sqlite3_open(path, &db)
        let far = String(repeating: "a", count: 600) + "?"     // the only "?" sits at index 600
        let near = String(repeating: "b", count: 100) + "?"    // comfortably inside the window
        let sql = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INT, unread_count INT, deleted_count INT, source INT);
        INSERT INTO mailboxes VALUES (1,'imap://\(Self.acct)/INBOX',2,0,0,NULL);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        INSERT INTO subjects VALUES (100,'Quiet subject');
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        INSERT INTO addresses VALUES (1000,'alice@x.io','Alice');
        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INT, attachment_id TEXT, name TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        INSERT INTO summaries VALUES (300,'\(far)'),(301,'\(near)');
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject_prefix TEXT, subject INT, summary INT,
          sender INT, date_sent INT, date_received INT, mailbox INT, read INT, flagged INT, deleted INT);
        INSERT INTO messages VALUES
          (10,NULL,100,300,1000,1784000000,1784000000,1,1,0,0),
          (11,NULL,100,301,1000,1784000100,1784000100,1,1,0,0);
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)

        let rows = try rowsByID(try EnvelopeIndex(explicitPath: path))
        func ask(_ id: Int) throws -> Bool {
            let r = try #require(rows[id])
            return Analytics.hasQuestion(Analytics.Row(
                rowid: id, senderAddress: nil, senderName: nil, subject: (r["subject"] ?? nil) ?? "",
                dateReceived: nil, read: true, flagged: false, hasAttachment: false, mailboxRowid: 1,
                snippet: r["snippet"] ?? nil))
        }
        #expect(try ask(11), "positive control: a question inside the window IS seen")
        #expect(try !ask(10), "a question at character 600 is outside the oracle's window")
        // (a) the SQL bound: truncation happens in the query, not only in Swift.
        #expect(((rows[10]?["snippet"] ?? nil) ?? "").count == 500)

        // (b) the Swift bound, exercised directly. `Analytics.Row` is public and callers may build
        // one from a source that did not truncate, so `hasQuestion` must not trust its input.
        let untruncated = Analytics.Row(
            rowid: 99, senderAddress: nil, senderName: nil, subject: "Quiet subject",
            dateReceived: nil, read: true, flagged: false, hasAttachment: false, mailboxRowid: 1,
            snippet: far)
        #expect(!Analytics.hasQuestion(untruncated),
                "hasQuestion must apply the window itself, not rely on the caller having done it")
    }
}
