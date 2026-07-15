import Testing
import Foundation
import SQLite3
@testable import MessagesKit
import AppleKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Builds a temp SQLite file with the chat.db columns ChatDB actually queries,
/// seeded with known rows. Lets us test the I/O-coupled filter/scoring/shaping
/// layer (where the empty-vs-nil `--contact` privacy bug lived) without touching
/// the real store. Deleted on deinit.
final class ChatFixture {
    let path: String
    /// Message dates are set relative to `now` so a `hours: 24` query always
    /// includes them regardless of when the test runs.
    let base: Int64

    init() throws {
        path = NSTemporaryDirectory() + "apple-cli-fixture-\(UUID().uuidString).sqlite"
        base = Int64((Date().timeIntervalSince1970 - 3600 - MessageTime.appleUnixOffset) * 1_000_000_000)

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Err.open }
        defer { sqlite3_close(db) }

        exec(db, """
            CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
                room_name TEXT, guid TEXT, service_name TEXT, group_id TEXT, style INTEGER);
            CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
                is_from_me INTEGER, handle_id INTEGER, cache_roomnames TEXT, service TEXT,
                cache_has_attachments INTEGER, date INTEGER, error INTEGER);
            """)

        exec(db, "INSERT INTO handle VALUES (1,'+12125550100','iMessage'),(2,'+12125550101','SMS');")
        exec(db, """
            INSERT INTO chat VALUES
            (1,'chat999','Test Group','chat999','iMessage;+;chat999','iMessage','G1',43);
            """)
        exec(db, "INSERT INTO chat_handle_join VALUES (1,2);")

        // Text messages (bind via exec — no blobs).
        exec(db, """
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error) VALUES
            (1,'g1','hello from friend',0,1,'iMessage',\(base),0),
            (2,'g2','my reply',1,1,'iMessage',\(base - 100),0),
            (4,'g4','group hi',0,2,'SMS',\(base - 300),0),
            (5,'g5','error message',0,1,'iMessage',\(base - 400),1);
            """)
        exec(db, "UPDATE message SET cache_roomnames='chat999' WHERE ROWID=4;")

        // attributedBody-only message (NULL text) — bind the blob for "decoded body".
        let blob: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b, 12]
            + Array("decoded body".utf8)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO message (ROWID,guid,attributedBody,is_from_me,handle_id,service,date,error) VALUES (3,'g3',?1,0,1,'iMessage',?2,0)", -1, &stmt, nil)
        blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(blob.count), SQLITE_TRANSIENT) }
        sqlite3_bind_text(stmt, 2, String(base - 200), -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
        for s in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    enum Err: Error { case open }
    private func exec(_ db: OpaquePointer?, _ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
}

@Suite("ChatDB against a seeded fixture")
struct ChatDBFixtureTests {
    private func makeDB(_ fx: ChatFixture, book: AddressBook) throws -> ChatDB {
        try ChatDB(path: fx.path, book: book, copyToTemp: false)
    }
    private let friendBook = AddressBook(contacts: ["12125550100": "Friend Name"])

    @Test func recentNoFilterReturnsAllNewestFirst() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        #expect(msgs.count == 5)
        #expect(msgs.first?.rowid == 1)            // newest first
        #expect(msgs.map(\.rowid) == [1, 2, 3, 4, 5])
    }

    @Test func attributedBodyDecodedInQuery() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        let blobMsg = msgs.first { $0.rowid == 3 }
        #expect(blobMsg?.body == "decoded body")  // NULL text → attributedBody decoded
    }

    @Test func senderResolution() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        #expect(msgs.first { $0.rowid == 1 }?.sender == "Friend Name") // AddressBook hit
        #expect(msgs.first { $0.rowid == 2 }?.sender == "You")          // is_from_me
        // handle 2 has no contact but is in a named chat → chat display-name fallback.
        #expect(msgs.first { $0.rowid == 4 }?.sender == "Test Group")
        #expect(msgs.first { $0.rowid == 4 }?.group_name == "Test Group")
    }

    @Test func filterByHandleRestrictsResults() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: [1], limit: 100)
        #expect(Set(msgs.map(\.rowid)) == [1, 2, 3, 5]) // handle 1 only (not the group msg)
    }

    /// REGRESSION: an empty (non-nil) filter must return NOTHING, not leak all
    /// conversations. This is the critic's CRITICAL finding.
    @Test func emptyFilterReturnsNothing() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        #expect(db.recent(hours: 24, handleRowIds: [], limit: 100).isEmpty)
    }

    @Test func searchExactSubstringScores1() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let r = db.search(term: "hello", hours: 24, threshold: 0.6, match: .fuzzy)
        #expect(r.matches.contains { $0.rowid == 1 && $0.score == 1.0 })
    }

    @Test func searchDecodesAttributedBody() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let r = db.search(term: "decoded", hours: 24, threshold: 0.6, match: .contains)
        #expect(r.matches.contains { $0.rowid == 3 }) // found via decoded attributedBody
    }

    @Test func availabilityDetectsIMessage() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        let a = db.availability(recipient: "+12125550100")
        #expect(a.available)                 // handle 1 = iMessage, errors(1) < text_count(4)
        #expect(a.service == "iMessage")
    }

    @Test func availabilitySmsFallbackForUnknownNumber() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        let a = db.availability(recipient: "+12125550199") // no history
        #expect(!a.available)
        #expect(a.service == "SMS")          // has digits → SMS fallback
    }

    @Test func namedChatsListsGroup() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        let chats = db.namedChats()
        #expect(chats.count == 1)
        #expect(chats.first?.display_name == "Test Group")
        #expect(chats.first?.chat_identifier == "chat999")
    }

    @Test func handleRowIdLookupTriesPhoneVariants() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        // stored as +12125550100; a bare 10-digit query must still resolve via variants.
        #expect(db.handleRowIds(forPhone: "2125550100") == [1])
    }
}

@Suite("AddressBook seeded")
struct AddressBookSeededTests {
    @Test func nameForHandlePhoneAndCountryCode() {
        let book = AddressBook(contacts: ["12125550100": "Alice"])
        #expect(book.nameForHandle("+1 (212) 555-0100") == "Alice")
        #expect(book.nameForHandle("2125550100") == "Alice") // 10-digit → adds country code
    }

    @Test func nameForHandleEmail() {
        let book = AddressBook(contacts: ["bob@example.com": "Bob"])
        #expect(book.nameForHandle("Bob@Example.com") == "Bob") // case-insensitive
    }

    @Test func nameForHandleMiss() {
        #expect(AddressBook().nameForHandle("+12125550199") == nil)
    }

    @Test func findByNameRanksAndDedups() {
        let book = AddressBook(
            contacts: ["12125550110": "Jane Doe", "12125550111": "Jane Doe",
                       "12125550112": "Bobby Tables"],
            details: [:])
        let matches = book.findByName("Jane")
        // Both "Jane Doe" numbers score 0.95 (exact token); deduped by phone,
        // deterministic order by phone asc.
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { abs($0.score - 0.95) < 1e-9 })
        #expect(matches.map(\.phone) == ["12125550110", "12125550111"])
    }
}
