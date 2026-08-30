import Testing
import Foundation
import SQLite3
@testable import MailKit

/// Where `needs-response` gets its "already replied" suppression set.
///
/// Both defects here were invisible: the command still ran, still returned plausible items, and
/// simply never suppressed anything.
///
/// Measured on a real live store. The one that actually bit was the PRIORITY miss: one
/// account owned both a near-empty `Sent` (nearly nothing) and a populated
/// `Sent Messages`, and the old
/// `first(where: isSentMailbox)` took the former by ROWID accident — so the whole suppression set
/// was one stale subject. The ORDERING miss was masked behind it and goes live the moment
/// priority is fixed: unordered-first-200 of `Sent Messages` spans a much wider window, where the
/// newest-200 the oracle reads is far narrower.
///
/// (An earlier draft of this comment cited a different, wider date window. That number came from a
/// probe with no mailbox predicate — it measured the whole store, not the Sent mailbox.
/// Recorded because a plausible-looking measurement is the easiest kind of wrong claim to ship.)
///
/// The fixture below makes rowid order and date order DISAGREE on purpose. A fixture where they
/// happen to coincide would pass under the bug — which is exactly how this shipped.
@Suite("needs-response suppression sourcing")
struct NeedsResponseSourcingTests {
    static let acctA = "AAAA1111-1111-1111-1111-111111111111"
    static let acctB = "BBBB2222-2222-2222-2222-222222222222"

    /// Account A owns BOTH `Sent` and `Sent Messages`, so the oracle's fallback PRIORITY is
    /// observable rather than just its membership test. Account B owns `Sent Items` and is ordered
    /// FIRST, which is what makes the missing account filter observable: an unfiltered
    /// `first(where: isSentMailbox)` picks the name "Sent Items", which account A does not have.
    ///
    /// Sent rows are inserted in ascending ROWID with deliberately scrambled dates:
    ///
    /// | rowid | subject   | effective date | rank by date |
    /// |-------|-----------|----------------|--------------|
    /// | 10    | oldest    | 1000           | 5th          |
    /// | 11    | newest    | 5000           | 1st          |
    /// | 12    | middle    | 3000           | 3rd          |
    /// | 13    | recv-only | 4000 (date_sent 0 → date_received) | 2nd |
    /// | 14    | second-oldest | 2000       | 4th          |
    static func fixture() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-nr-\(UUID().uuidString).sqlite").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK, "fixture open failed")
        let sql = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INT, unread_count INT, deleted_count INT, source INT);
        INSERT INTO mailboxes VALUES
          (1,'imap://\(acctB)/Sent Items',1,0,0,NULL),
          (2,'imap://\(acctA)/Sent',0,0,0,NULL),
          (3,'imap://\(acctA)/Sent Messages',5,0,0,NULL),
          (4,'imap://\(acctA)/INBOX',0,0,0,NULL);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        INSERT INTO subjects VALUES
          (100,'oldest'),(101,'newest'),(102,'middle'),(103,'recv-only'),(104,'second-oldest'),
          (105,'other-account-sent');
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        INSERT INTO addresses VALUES (1000,'me@a.test','Me');
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INT, global_message_id INT,
          subject_prefix TEXT, subject INT, summary INT, sender INT, date_sent INT, date_received INT,
          mailbox INT, flags INT, read INT, flagged INT, deleted INT, size INT, conversation_id INT, flag_color INT);
        INSERT INTO messages VALUES
          (10, 1, NULL, NULL, 100, NULL, 1000, 1000, 1000, 3, 0, 1, 0, 0, 10, 1, 0),
          (11, 2, NULL, NULL, 101, NULL, 1000, 5000, 5000, 3, 0, 1, 0, 0, 10, 2, 0),
          (12, 3, NULL, NULL, 102, NULL, 1000, 3000, 3000, 3, 0, 1, 0, 0, 10, 3, 0),
          (13, 4, NULL, NULL, 103, NULL, 1000,    0, 4000, 3, 0, 1, 0, 0, 10, 4, 0),
          (14, 5, NULL, NULL, 104, NULL, 1000, 2000, 2000, 3, 0, 1, 0, 0, 10, 5, 0),
          (20, 6, NULL, NULL, 105, NULL, 1000, 9999, 9999, 1, 0, 1, 0, 0, 10, 6, 0);
        CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INT, attachment_id TEXT, name TEXT);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INT, address INT, type INT, position INT);
        CREATE TABLE labels (message_id INT, mailbox_id INT);
        CREATE TABLE message_references (ROWID INTEGER PRIMARY KEY, message INT, reference INT, is_originator INT);
        """
        // Assert rather than discard: a half-applied schema otherwise surfaces as a confusing
        // failure three assertions later, in a test that looks like it is about ordering.
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "fixture schema failed")
        sqlite3_close(db)
        return path
    }

    /// Each call builds a fresh temp DB. `EnvelopeIndex` reads it eagerly in `init`, so the file
    /// can be unlinked immediately — otherwise every `swift test` run strands one SQLite file per
    /// test in `$TMPDIR` (review-caught: 170 had already accumulated).
    func index() throws -> EnvelopeIndex {
        let path = Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try EnvelopeIndex(explicitPath: path)
    }

    func subjects(_ rows: [[String: String?]]) -> [String] {
        rows.map { strVal($0["subject"]) ?? "" }
    }

    // MARK: ordering

    /// POSITIVE CONTROL for the whole suite: rowid order really is different from date order in
    /// this fixture. If these ever coincide, every ordering assertion below becomes vacuous.
    @Test("control: the fixture's rowid order and date order genuinely disagree")
    func fixtureIsDiscriminating() throws {
        let idx = try index()
        let byRowid = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                                     sinceUnix: nil))
        let byDate = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                                    sinceUnix: nil, slice: .newestFirst))
        #expect(byRowid.count == 5 && byDate.count == 5)
        #expect(byRowid != byDate, "fixture must not have rowid order == date order")
    }

    @Test("newestFirst orders by date_sent descending")
    func newestFirstOrdering() throws {
        let idx = try index()
        let got = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                                 sinceUnix: nil, slice: .newestFirst))
        #expect(got == ["newest", "recv-only", "middle", "second-oldest", "oldest"])
    }

    /// THE defect. A bounded slice must take the newest N, not an arbitrary N. Under the old code
    /// this returned ["oldest", "newest"] — insertion order — so on a real store the suppression
    /// set was years stale.
    @Test("a limited newestFirst read takes the NEWEST rows, not the first-inserted ones")
    func limitTakesNewest() throws {
        let idx = try index()
        let got = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                                 sinceUnix: nil, slice: .newest(2)))
        #expect(got == ["newest", "recv-only"])
        #expect(!got.contains("oldest"), "the oldest row must not survive a newest-first limit")
    }

    /// `date_sent` is 0 for some Sent rows, where the meaningful timestamp is `date_received`.
    /// Ordering on a raw `date_sent` would sort those to the very bottom; `recv-only` ranking 2nd
    /// proves the COALESCE/NULLIF fallback works.
    @Test("a row with date_sent 0 is ranked by date_received, not sunk to last")
    func coalescesToDateReceived() throws {
        let idx = try index()
        let got = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                                 sinceUnix: nil, slice: .newestFirst))
        #expect(got.firstIndex(of: "recv-only") == 1)
    }

    /// The default must stay unordered so the aggregate callers (`stats`, `top-senders`) do not
    /// silently acquire a sort over a six-figure row count for results they only count.
    @Test("the default order is unchanged for existing callers")
    func defaultStaysUnordered() throws {
        let idx = try index()
        let a = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages", sinceUnix: nil))
        let b = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                               sinceUnix: nil, slice: .all))
        #expect(a == b)
        // Deliberately NOT asserting a specific first element. `.all` imposes no ORDER BY, so the
        // scan order is SQLite's to choose and would change if an index on `messages.mailbox` were
        // ever added. The contract is "same rows, no ordering imposed" — pin that, not an artifact.
        #expect(Set(a) == Set(["oldest", "newest", "middle", "recv-only", "second-oldest"]))
    }

    /// `awaiting-reply` needs ordered-but-UNBOUNDED: it applies its own bound after filtering out
    /// already-answered messages, so bounding the read would drop candidates the oracle still
    /// scans past (`if resultCount >= max_results then exit repeat` counts RESULTS, not rows read).
    @Test("newestFirst orders without bounding, for callers that bound after filtering")
    func newestFirstIsUnbounded() throws {
        let idx = try index()
        let got = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                                 sinceUnix: nil, slice: .newestFirst))
        #expect(got.count == 5, "must not bound")
        #expect(got == ["newest", "recv-only", "middle", "second-oldest", "oldest"])
    }

    /// A zero or negative bound must mean "no rows", never "unlimited".
    ///
    /// The first cut wrote `if let limit, limit > 0`, so `limit: 0` fell through to NO `LIMIT` at
    /// all and silently returned everything — the opposite of the request, and the dangerous
    /// direction to be wrong in for a bound whose whole job is to cap a read.
    @Test("a zero or negative bound returns nothing, never everything")
    func nonPositiveBoundReturnsNothing() throws {
        let idx = try index()
        for n in [0, -1, -1000] {
            let got = try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                            sinceUnix: nil, slice: .newest(n))
            #expect(got.isEmpty, "slice .newest(\(n)) returned \(got.count) rows")
        }
        // Control: the same call with a positive bound does return rows, so "empty" above is the
        // clamp and not a broken fixture.
        #expect(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages",
                                      sinceUnix: nil, slice: .newest(1)).count == 1)
    }

    // MARK: account scoping

    /// The oracle resolves `mailbox "Sent Messages" of targetAccount` (smart_inbox.py:274-283).
    /// Without the account filter, another account's Sent mail entered the suppression set and
    /// silently hid messages based on replies sent from a different mailbox entirely.
    @Test("a Sent read is confined to the requested account")
    func sentIsAccountScoped() throws {
        let idx = try index()
        let a = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: "Sent Messages", sinceUnix: nil))
        #expect(!a.contains("other-account-sent"))
        // Control: the other account's row is real and reachable — so its absence above is
        // scoping, not an empty fixture.
        let b = subjects(try idx.analyticsRows(accountUUID: Self.acctB, mailboxName: "Sent Items", sinceUnix: nil))
        #expect(b == ["other-account-sent"])
    }

    // MARK: Sent-mailbox selection priority

    /// `first(where: isSentMailbox)` returns whichever candidate the array happens to hold first.
    /// The oracle tries `Sent Messages` → `Sent` → `Sent Items` in that order, and account A owns
    /// two of them, so the choice is observable.
    @Test("Sent selection follows the oracle's fallback priority, not array order")
    func sentPriority() {
        #expect(Analytics.preferredSentMailbox(["Sent", "Sent Messages"]) == "Sent Messages")
        #expect(Analytics.preferredSentMailbox(["Sent Items", "Sent"]) == "Sent")
        #expect(Analytics.preferredSentMailbox(["Sent Items"]) == "Sent Items")
        #expect(Analytics.preferredSentMailbox(["Archive", "INBOX"]) == nil)
        // `Sent Mail` is a CLI EXTRA appended AFTER the oracle's three: Gmail-backed accounts
        // expose only that name, so the oracle finds no Sent mailbox there and skips suppression
        // entirely. Matching it is additive (strict superset holds) and stops the filter being a
        // no-op on Gmail. It must never outrank an oracle name.
        #expect(Analytics.preferredSentMailbox(["[Gmail]/Sent Mail"]) == "[Gmail]/Sent Mail")
        #expect(Analytics.preferredSentMailbox(["[Gmail]/Sent Mail", "Sent Messages"]) == "Sent Messages")
        #expect(Analytics.preferredSentMailbox(["[Gmail]/Sent Mail", "Sent Items"]) == "Sent Items")
        // Nested paths match on the leaf. This is a CLI EXTRA, not oracle parity: the oracle's
        // `mailbox "Sent" of targetAccount` cannot resolve a nested mailbox at all. Kept because
        // `resolveMailboxes` matches leaf-or-path everywhere else in this codebase.
        #expect(Analytics.preferredSentMailbox(["Work/Sent"]) == "Work/Sent")
        // Priority beats position even when the lower-priority name comes first AND is nested.
        #expect(Analytics.preferredSentMailbox(["a/Sent Items", "b/Sent Messages"]) == "b/Sent Messages")
    }

    /// The REAL shape of the missing-account-filter defect, which is not a leak.
    ///
    /// `resolveMailboxes` skips mailboxes whose `accountID` differs, so another account's mail
    /// could never enter the result. What the unfiltered lookup did was pick a mailbox NAME from
    /// whichever account matched first — here account B's "Sent Items", a name account A does not
    /// have — after which the account-scoped query matches nothing and the suppression set is
    /// EMPTY. The filter silently stops filtering, which is why nothing ever surfaced it.
    @Test("REGRESSION: an unfiltered Sent lookup picks a name this account lacks, yielding nothing")
    func unfilteredLookupSilentlyYieldsNothing() throws {
        let idx = try index()

        // What the old code did: no account filter, first match wins.
        let unfiltered = idx.mailboxes.first(where: { Analytics.isSentMailbox($0.url.path) })?.url.path
        #expect(unfiltered == "Sent Items", "fixture must reproduce the wrong-account pick")
        let stale = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: unfiltered!,
                                                   sinceUnix: nil, slice: .newest(200)))
        #expect(stale.isEmpty, "the old path yields an empty suppression set — a silent no-op")

        // What the fixed code does: own account, oracle priority.
        let ownPaths = idx.mailboxes.filter { $0.url.accountID == Self.acctA }.map(\.url.path)
        let fixed = Analytics.preferredSentMailbox(ownPaths)
        #expect(fixed == "Sent Messages")
        let good = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: fixed!,
                                                  sinceUnix: nil, slice: .newest(200)))
        #expect(good.count == 5, "the fixed path must actually find the account's sent mail")
    }

    /// End-to-end through the real index object: the account's own Sent mailbox is chosen by
    /// priority, and reading it newest-first with a bound yields the newest subjects.
    @Test("the command's sourcing path picks account A's Sent Messages and its newest rows")
    func endToEndSourcing() throws {
        let idx = try index()
        let ownPaths = idx.mailboxes.filter { $0.url.accountID == Self.acctA }.map(\.url.path)
        let sent = Analytics.preferredSentMailbox(ownPaths)
        #expect(sent == "Sent Messages")
        let got = subjects(try idx.analyticsRows(accountUUID: Self.acctA, mailboxName: sent!,
                                                 sinceUnix: nil, slice: .newest(3)))
        #expect(got == ["newest", "recv-only", "middle"])
    }
}
