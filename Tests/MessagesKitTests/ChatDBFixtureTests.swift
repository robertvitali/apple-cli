import Testing
import Foundation
import SQLite3
@testable import MessagesKit
import AppleKit
import TestSupport

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Builds a temp SQLite file with the chat.db columns ChatDB actually queries,
/// seeded with known rows. Lets us test the I/O-coupled filter/scoring/shaping
/// layer (where the empty-vs-nil `--contact` privacy bug lived) without touching
/// the real store. Deleted on deinit.
final class ChatFixture {
    private let scratch = ScratchDirs("messages-chatdb-fixture")
    let path: String
    let homePath: String
    /// A real file on disk, so `Attachment.exists` has a true case to prove and is not
    /// vacuously false for every row.
    let presentAttachmentPath: String
    let symlinkAttachmentPath: String
    /// Message dates are set relative to `now` so a `hours: 24` query always
    /// includes them regardless of when the test runs.
    let base: Int64

    init(includeOptionalAttachmentColumns: Bool = true) throws {
        let root = try scratch.directory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let attachmentDir = home.appendingPathComponent("Library/Messages/Attachments/zz",
                                                        isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
        path = root.appendingPathComponent("chat.sqlite").path
        homePath = home.path
        presentAttachmentPath = attachmentDir.appendingPathComponent("apple-cli-present.png").path
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: presentAttachmentPath))
        symlinkAttachmentPath = home.appendingPathComponent("Library/Messages/Attachments/link").path
        try FileManager.default.createSymbolicLink(atPath: symlinkAttachmentPath,
                                                   withDestinationPath: "/Volumes/example")
        base = Int64((Date().timeIntervalSince1970 - 3600 - MessageTime.appleUnixOffset) * 1_000_000_000)

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Err.open }
        defer { sqlite3_close(db) }

        let optionalAttachmentColumns = includeOptionalAttachmentColumns
            ? ", is_sticker INTEGER, hide_attachment INTEGER"
            : ""
        exec(db, """
            CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
                room_name TEXT, guid TEXT, service_name TEXT, group_id TEXT, style INTEGER);
            CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
                is_from_me INTEGER, handle_id INTEGER, cache_roomnames TEXT, service TEXT,
                cache_has_attachments INTEGER, date INTEGER, error INTEGER);
            CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT,
                mime_type TEXT, uti TEXT, transfer_name TEXT, total_bytes INTEGER\(optionalAttachmentColumns));
            CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
            """)

        // Handle 3 exists only to give the group chat a second participant; it sends no
        // messages, so no message-shaping expectation depends on it.
        exec(db, """
            INSERT INTO handle VALUES
            (1,'+12125550100','iMessage'),(2,'+12125550101','SMS'),(3,'+12125550102','iMessage');
            """)
        // Chat 3 is the 1:1 conversation with handle 1 (style 45, no display_name — exactly how
        // chat.db stores a direct conversation), so `is_group` has a real false case that still
        // carries an identifier and guid. Chat 4 is a named group with NO messages and no
        // participants, giving `last_activity` a null case and `--name`/`--limit` a second row.
        exec(db, """
            INSERT INTO chat VALUES
            (1,'chat999','Test Group','chat999','iMessage;+;chat999','iMessage','G1',43),
            (2,'chatEMPTY','','chatEMPTY','iMessage;+;chatEMPTY','iMessage','G2',43),
            (3,'+12125550100',NULL,NULL,'iMessage;-;+12125550100','iMessage',NULL,45),
            (4,'chat888','Other Group','chat888','iMessage;+;chat888','iMessage','G4',43);
            """)
        // (1,2) and (1,3): the group's two participants. (3,1): the 1:1 chat's single member —
        // it is handle 1's ONLY chat_handle_join row, so the `chatDisplayName` fallback still
        // resolves deterministically (chat 3 has no display_name, exactly as before).
        exec(db, "INSERT INTO chat_handle_join VALUES (1,2),(1,3),(3,1);")

        // Text messages (bind via exec — no blobs).
        exec(db, """
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error) VALUES
            (1,'g1','hello from friend',0,1,'iMessage',\(base),0),
            (2,'g2','my reply',1,1,'iMessage',\(base - 100),0),
            (4,'g4','group hi',0,2,'SMS',\(base - 300),0),
            (5,'g5','error message',0,1,'iMessage',\(base - 400),1);
            """)
        exec(db, "UPDATE message SET cache_roomnames='chat999' WHERE ROWID=4;")
        // MSG-2: a chat whose display_name is '' — the oracle emits NO group annotation.
        exec(db, "UPDATE message SET cache_roomnames='chatEMPTY' WHERE ROWID=5;")

        // attributedBody-only message (NULL text) — bind the blob for "decoded body".
        let blob: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b, 12]
            + Array("decoded body".utf8)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO message (ROWID,guid,attributedBody,is_from_me,handle_id,service,date,error) VALUES (3,'g3',?1,0,1,'iMessage',?2,0)", -1, &stmt, nil)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(blob.count), SQLITE_TRANSIENT) }
        sqlite3_bind_text(stmt, 2, String(base - 200), -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt); sqlite3_finalize(stmt)

        // MSG-6: attachment-only — NULL text AND NULL attributedBody. Before the body-guard
        // fix this row was dropped outright. MSG-7 keeps the negative case, so the fix cannot
        // be "achieved" by deleting the guard. MSG-8 has a real join row while the cache flag
        // is 0, pinning the authoritative source of truth. MSG-11 proves a cache flag alone is
        // not enough to preserve a bodyless row because there are no file details to return.
        exec(db, """
            INSERT INTO message (ROWID,guid,is_from_me,handle_id,service,date,error,cache_has_attachments) VALUES
            (6,'g6',0,1,'iMessage',\(base - 500),0,1),
            (7,'g7',0,1,'iMessage',\(base - 600),0,0),
            (11,'g11',0,1,'iMessage',\(base - 1000),0,1);
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,cache_has_attachments) VALUES
            (8,'g8','cache miss attachment',0,1,'iMessage',\(base - 700),0,0);
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,cache_has_attachments) VALUES
            (9,'g9','path semantics attachment',0,1,'iMessage',\(base - 800),0,1);
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,cache_has_attachments) VALUES
            (10,'g10','null attachment fields',0,1,'iMessage',\(base - 900),0,1);
            """)
        // Which chat each message belongs to. Message 3 is deliberately joined to NO chat, so
        // the "no chat row → nulls, is_group false" case is real rather than assumed. Message 4
        // is in BOTH the group (chat ROWID 1) and the 1:1 chat (ROWID 3), pinning the
        // first-by-chat-ROWID rule; messages 7 and 11 are shaped away but are joined anyway so
        // the fixture matches how chat.db actually looks.
        exec(db, """
            INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (3,1),(3,2),(1,4),(3,4),(2,5),(3,6),(3,7),(3,8),(3,9),(3,10),(3,11);
            """)

        // One attachment whose file is really on disk under the injected home (exists → true)
        // and one that is not, written tilde-relative the way chat.db actually stores them.
        if includeOptionalAttachmentColumns {
            exec(db, """
                INSERT INTO attachment (ROWID,guid,filename,mime_type,uti,transfer_name,total_bytes,is_sticker,hide_attachment) VALUES
                (10,'a10','~/Library/Messages/Attachments/zz/apple-cli-present.png','image/png','public.png','photo.png',3,0,0),
                (11,'a11','~/Library/Messages/Attachments/zz/apple-cli-absent.mov','video/quicktime','com.apple.quicktime-movie','clip.mov',99,1,0),
                (12,'a12','~/Library/Messages/Attachments/zz/apple-cli-doc.pdf','application/pdf','com.adobe.pdf','doc.pdf',42,0,1),
                (13,'a13','~/Library/Messages/Attachments/zz/apple-cli-cache-miss.png','image/png','public.png','cache-miss.png',8,0,0),
                (14,'a14','relative/apple-cli.png','image/png','public.png','relative.png',14,0,0),
                (15,'a15','~/Library/Messages/Attachments/zz/../zz/apple-cli-present.png','image/png','public.png','standardized.png',15,0,0),
                (16,'a16','/net/example.invalid/apple-cli.png','image/png','public.png','net.png',16,0,0),
                (17,'a17','/home/example/apple-cli.png','image/png','public.png','home.png',17,0,0),
                (19,'a19','/Network/Servers/example.invalid/apple-cli.png','image/png','public.png','network.png',19,0,0),
                (20,'a20','/Volumes/example/apple-cli.png','image/png','public.png','volume.png',20,0,0),
                (21,'a21','~/Library/Messages/Attachments/link/apple-cli.png','image/png','public.png','symlink.png',21,0,0),
                (18,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
                INSERT INTO message_attachment_join VALUES (6,10),(6,11),(5,12),(8,13),(9,14),(9,15),(9,16),(9,17),(9,19),(9,20),(9,21),(10,18);
                """)
        } else {
            exec(db, """
                INSERT INTO attachment (ROWID,guid,filename,mime_type,uti,transfer_name,total_bytes) VALUES
                (10,'a10','~/Library/Messages/Attachments/zz/apple-cli-present.png','image/png','public.png','photo.png',3),
                (11,'a11','~/Library/Messages/Attachments/zz/apple-cli-absent.mov','video/quicktime','com.apple.quicktime-movie','clip.mov',99),
                (12,'a12','~/Library/Messages/Attachments/zz/apple-cli-doc.pdf','application/pdf','com.adobe.pdf','doc.pdf',42),
                (13,'a13','~/Library/Messages/Attachments/zz/apple-cli-cache-miss.png','image/png','public.png','cache-miss.png',8),
                (14,'a14','relative/apple-cli.png','image/png','public.png','relative.png',14),
                (15,'a15','~/Library/Messages/Attachments/zz/../zz/apple-cli-present.png','image/png','public.png','standardized.png',15),
                (16,'a16','/net/example.invalid/apple-cli.png','image/png','public.png','net.png',16),
                (17,'a17','/home/example/apple-cli.png','image/png','public.png','home.png',17),
                (19,'a19','/Network/Servers/example.invalid/apple-cli.png','image/png','public.png','network.png',19),
                (20,'a20','/Volumes/example/apple-cli.png','image/png','public.png','volume.png',20),
                (21,'a21','~/Library/Messages/Attachments/link/apple-cli.png','image/png','public.png','symlink.png',21),
                (18,NULL,NULL,NULL,NULL,NULL,NULL);
                INSERT INTO message_attachment_join VALUES (6,10),(6,11),(5,12),(8,13),(9,14),(9,15),(9,16),(9,17),(9,19),(9,20),(9,21),(10,18);
                """)
        }
        // MSG-5 also carries an attachment: it has real text, so it is reachable by the SEARCH
        // path, which is where the two message shapes would otherwise silently diverge.
        exec(db, "UPDATE message SET cache_has_attachments=1 WHERE ROWID=5;")
    }

    deinit {
        for s in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    enum Err: Error { case open, exec(String) }
    private func exec(_ db: OpaquePointer?, _ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Err.open }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        defer { sqlite3_free(err) }
        guard rc == SQLITE_OK else {
            throw Err.exec(err.map { String(cString: $0) } ?? "unknown sqlite error")
        }
    }
}

@Suite("ChatDB against a seeded fixture")
struct ChatDBFixtureTests {
    private func makeDB(_ fx: ChatFixture, book: AddressBook) throws -> ChatDB {
        try ChatDB(path: fx.path, book: book, copyToTemp: false, homeDirectoryForTilde: fx.homePath)
    }
    private let friendBook = AddressBook(contacts: ["12125550100": "Friend Name"])

    @Test func recentNoFilterReturnsAllNewestFirst() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        #expect(msgs.count == 9)
        #expect(msgs.first?.rowid == 1)            // newest first
        // 6 is the attachment-only row; 7 is body-less with nothing attached and stays dropped.
        #expect(msgs.map(\.rowid) == [1, 2, 3, 4, 5, 6, 8, 9, 10])
    }

    /// MSG-2. The oracle keeps '' in chat_mapping and filters at USE (`if group_chat_name:`),
    /// so an empty display_name produces NO group annotation. Binding Optional("") through gave
    /// the wire three states (absent / "" / name) where the oracle has two, so a consumer testing
    /// `group_name is not None` read a 1:1 message as a group message.
    @Test func emptyChatDisplayNameEmitsNoGroup() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        let empty = msgs.first { $0.rowid == 5 }
        #expect(empty != nil, "precondition: the empty-display-name message is in range")
        #expect(empty?.group_name == nil, "'' must be absent, not empty-string")
        // Positive control: a real display_name still comes through, so this is not just
        // suppressing every group annotation.
        #expect(msgs.first { $0.rowid == 4 }?.group_name == "Test Group")
    }

    /// Pins WHERE the truthiness filter lives. The oracle's `get_chat_mapping` KEEPS the ''
    /// entry and each consumer filters at use (`if group_chat_name:`). Moving our filter into
    /// `chatMapping()` would make every other test still pass while silently changing that
    /// public API's contract, so assert the empty entry survives the mapping.
    @Test func chatMappingKeepsEmptyDisplayNameLikeTheOracle() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        let map = db.chatMapping()
        #expect(map["chatEMPTY"] == "", "the mapping keeps ''; the FILTER belongs at the use site")
        #expect(map["chat999"] == "Test Group")
    }

    /// The SEARCH path has the identical empty-`display_name` fix as `recent`, and had NO test —
    /// reverting `ChatDB.swift`'s search-side binding left the whole suite green, with only a live
    /// corpus measurement covering it. A corpus measurement evaporates the moment the corpus
    /// changes, so pin it here too.
    @Test func searchAlsoOmitsEmptyGroupName() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let hits = db.search(term: "error", hours: 24, threshold: 0.6, match: .contains).matches
        let empty = hits.first { $0.rowid == 5 }
        #expect(empty != nil, "precondition: the empty-display-name message is a search hit")
        #expect(empty?.group_name == nil, "'' must be absent on the search path too, not empty-string")
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
        #expect(Set(msgs.map(\.rowid)) == [1, 2, 3, 5, 6, 8, 9, 10]) // handle 1 only (not the group msg)
    }

    /// The attachment-only row (NULL text, NULL attributedBody) must SURVIVE shaping. It used
    /// to be dropped by the body guard, so a caller could never see the one class of message
    /// this metadata exists for.
    @Test func attachmentOnlyMessageSurvivesWithEmptyBody() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        let m = msgs.first { $0.rowid == 6 }
        #expect(m != nil, "attachment-only message must not be dropped")
        #expect(m?.body == "")
        #expect(m?.has_attachments == true)
    }

    /// Negative control for the guard fix: body-less AND nothing attached is still noise and
    /// stays dropped. Without this, deleting the guard entirely would pass the test above.
    @Test func bodylessMessageWithNoAttachmentIsStillSkipped() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        #expect(!msgs.contains { $0.rowid == 7 })
    }

    @Test func bodylessCacheFlagOnlyMessageIsStillSkipped() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)
        #expect(!msgs.contains { $0.rowid == 11 })
    }

    @Test func attachmentMetadataIsJoinedAndOrdered() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let m = db.recent(hours: 24, handleRowIds: nil, limit: 100).first { $0.rowid == 6 }
        let atts = try #require(m?.attachments)
        #expect(atts.count == 2)
        #expect(atts.map(\.rowid) == [10, 11])              // ORDER BY a.ROWID
        #expect(atts[0].transfer_name == "photo.png")
        #expect(atts[0].mime_type == "image/png")
        #expect(atts[0].uti == "public.png")
        #expect(atts[0].total_bytes == 3)
        #expect(atts[0].is_sticker == false)
        #expect(atts[0].hide_attachment == false)
        #expect(atts[1].is_sticker == true)
        #expect(atts[1].hide_attachment == false)
        #expect(atts[0].exists == true)                     // really on disk
        #expect(atts[1].exists == false)
        // Stored tilde-relative; `path` is the usable absolute form, `filename` is verbatim.
        #expect(atts[0].filename?.hasPrefix("~/") == true)
        #expect(atts[0].path == fx.presentAttachmentPath)
        #expect(atts[1].filename?.hasPrefix("~/") == true)
        #expect(atts[1].path?.hasPrefix("~") == false)
        #expect(atts[1].path?.hasSuffix("/Library/Messages/Attachments/zz/apple-cli-absent.mov") == true)
    }

    /// A message with no attachment gets an empty array, not a missing key or a nil.
    @Test func messageWithoutAttachmentsHasEmptyArray() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let m = db.recent(hours: 24, handleRowIds: nil, limit: 100).first { $0.rowid == 1 }
        #expect(m?.attachments.isEmpty == true)
        #expect(m?.has_attachments == false)
    }

    /// The two message shapes must not diverge: a caller that finds a message by search gets
    /// the same attachment metadata as one reading it from `recent`.
    @Test func searchCarriesAttachmentsToo() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        // Message 5 has text (so it is reachable by search) AND an attachment.
        let hit = db.search(term: "error", hours: 24, threshold: 0.6, match: .contains)
            .matches.first { $0.rowid == 5 }
        let m = try #require(hit)
        #expect(m.has_attachments == true)
        #expect(m.attachments.map(\.rowid) == [12])
        #expect(m.attachments.first?.transfer_name == "doc.pdf")
        #expect(m.attachments.first?.total_bytes == 42)

        // Negative side, so this is not just "every search hit reports an attachment".
        let plain = db.search(term: "hello", hours: 24, threshold: 0.6, match: .contains)
            .matches.first { $0.rowid == 1 }
        #expect(plain?.attachments.isEmpty == true)
        #expect(plain?.has_attachments == false)
    }

    @Test func joinRowsSetHasAttachmentsEvenWhenCacheFlagIsZero() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)

        let recent = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100)
            .first { $0.rowid == 8 })
        #expect(recent.attachments.map(\.rowid) == [13])
        #expect(recent.has_attachments == true)

        let searched = try #require(db.search(term: "cache miss", hours: 24, threshold: 0.6,
                                              match: .contains).matches.first { $0.rowid == 8 })
        #expect(searched.attachments.map(\.rowid) == [13])
        #expect(searched.has_attachments == true)
    }

    @Test func attachmentLookupKeepsRowsPastTheFirstChunk() throws {
        let fx = try ChatFixture()
        let start = fx.base - 10_000
        for rowid in 1000..<1605 {
            try fx.exec("""
                INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,cache_has_attachments)
                VALUES (\(rowid),'bulk-\(rowid)','bulk attachment \(rowid)',0,1,'iMessage',\(start - Int64(rowid)),0,1);
                INSERT INTO attachment (ROWID,guid,filename,mime_type,uti,transfer_name,total_bytes)
                VALUES (\(rowid),'bulk-att-\(rowid)','/tmp/apple-cli-bulk-\(rowid).png','image/png','public.png','bulk-\(rowid).png',1);
                INSERT INTO message_attachment_join VALUES (\(rowid),\(rowid));
                """)
        }

        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 700)
        let beforeBoundary = try #require(msgs.first { $0.rowid == 1499 })
        let afterBoundary = try #require(msgs.first { $0.rowid == 1500 })
        let final = try #require(msgs.first { $0.rowid == 1604 })
        #expect(beforeBoundary.attachments.map(\.rowid) == [1499])
        #expect(afterBoundary.attachments.map(\.rowid) == [1500])
        #expect(final.attachments.map(\.rowid) == [1604])
    }

    @Test func attachmentPathsAreAbsoluteStandardizedAndSafelyProbed() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msg = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100)
            .first { $0.rowid == 9 })
        let byRow = Dictionary(uniqueKeysWithValues: msg.attachments.map { ($0.rowid, $0) })

        let relative = try #require(byRow[14])
        #expect(relative.path == nil)
        #expect(relative.exists == nil)

        let standardized = try #require(byRow[15])
        #expect(standardized.path == fx.presentAttachmentPath)
        #expect(standardized.exists == true)

        let net = try #require(byRow[16])
        #expect(net.path == "/net/example.invalid/apple-cli.png")
        #expect(net.exists == nil)

        let home = try #require(byRow[17])
        #expect(home.path == "/home/example/apple-cli.png")
        #expect(home.exists == nil)

        let network = try #require(byRow[19])
        #expect(network.path == "/Network/Servers/example.invalid/apple-cli.png")
        #expect(network.exists == nil)

        let volume = try #require(byRow[20])
        #expect(volume.path == "/Volumes/example/apple-cli.png")
        #expect(volume.exists == nil)

        let symlink = try #require(byRow[21])
        #expect(symlink.path == fx.symlinkAttachmentPath + "/apple-cli.png")
        #expect(symlink.exists == nil)
    }

    @Test func nullAttachmentFieldsSurviveTheSQLPath() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msg = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100)
            .first { $0.rowid == 10 })
        let att = try #require(msg.attachments.first)
        #expect(att.rowid == 18)
        #expect(att.guid == nil)
        #expect(att.filename == nil)
        #expect(att.path == nil)
        #expect(att.exists == nil)
        #expect(att.mime_type == nil)
        #expect(att.uti == nil)
        #expect(att.transfer_name == nil)
        #expect(att.total_bytes == nil)
        #expect(att.is_sticker == nil)
        #expect(att.hide_attachment == nil)
        #expect(msg.has_attachments == true)
    }

    @Test func olderAttachmentSchemaStillReturnsJoinedRows() throws {
        let fx = try ChatFixture(includeOptionalAttachmentColumns: false)
        var db = try makeDB(fx, book: friendBook)
        let msg = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100)
            .first { $0.rowid == 6 })

        #expect(msg.attachments.map(\.rowid) == [10, 11])
        #expect(msg.attachments.allSatisfy { $0.is_sticker == nil })
        #expect(msg.attachments.allSatisfy { $0.hide_attachment == nil })
    }

    @Test func missingAttachmentMetadataColumnsStillReturnJoinedRows() throws {
        let fx = try ChatFixture()
        try fx.exec("""
            DROP TABLE attachment;
            CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY);
            INSERT INTO attachment VALUES (10),(11);
            """)
        var db = try makeDB(fx, book: friendBook)
        let msg = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100)
            .first { $0.rowid == 6 })

        #expect(msg.has_attachments == true)
        #expect(msg.attachments.map(\.rowid) == [10, 11])
        #expect(msg.attachments.allSatisfy { $0.guid == nil })
        #expect(msg.attachments.allSatisfy { $0.filename == nil })
        #expect(msg.attachments.allSatisfy { $0.total_bytes == nil })
    }

    @Test func missingAttachmentJoinCapabilityReturnsNoMetadata() throws {
        let fx = try ChatFixture()
        try fx.exec("DROP TABLE message_attachment_join;")
        var db = try makeDB(fx, book: friendBook)
        let msg = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100)
            .first { $0.rowid == 5 })

        #expect(msg.has_attachments == true)
        #expect(msg.attachments.isEmpty)
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
        // Chat 2's display_name is '' and chat 3 (the 1:1) has none, so only the two named
        // groups are listed — in chat-ROWID order, which the filters must not disturb.
        #expect(chats.map(\.display_name) == ["Test Group", "Other Group"])
        #expect(chats.first?.chat_identifier == "chat999")
    }

    // MARK: - Chat identity

    /// Every message says which chat it came from. The three cases that matter are a 1:1
    /// conversation (identifier + guid, `is_group` false), a group (`style` 43 → `is_group`
    /// true), and a message joined to no chat at all (nulls, and still NOT a group).
    @Test func recentCarriesChatIdentity() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)

        let direct = try #require(msgs.first { $0.rowid == 1 })
        #expect(direct.chat_identifier == "+12125550100")
        #expect(direct.chat_guid == "iMessage;-;+12125550100")
        #expect(direct.is_group == false)

        // Message 4 is joined to the group (chat ROWID 1) AND the 1:1 chat (ROWID 3); the
        // lowest chat ROWID wins, so a multi-chat row cannot report the wrong conversation.
        let group = try #require(msgs.first { $0.rowid == 4 })
        #expect(group.chat_identifier == "chat999")
        #expect(group.chat_guid == "iMessage;+;chat999")
        #expect(group.is_group == true)

        let orphan = try #require(msgs.first { $0.rowid == 3 })
        #expect(orphan.chat_identifier == nil)
        #expect(orphan.chat_guid == nil)
        #expect(orphan.is_group == false)
    }

    /// The two message shapes must not diverge — the same reasoning as `searchCarriesAttachmentsToo`.
    @Test func searchCarriesChatIdentity() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)

        // Message 5 sits in the '' -display-name group: `group_name` stays absent (the oracle's
        // shape) while `is_group` still reports the truth, which is the point of the new field.
        let grouped = try #require(db.search(term: "error", hours: 24, threshold: 0.6, match: .contains)
            .matches.first { $0.rowid == 5 })
        #expect(grouped.is_group == true)
        #expect(grouped.chat_identifier == "chatEMPTY")
        #expect(grouped.chat_guid == "iMessage;+;chatEMPTY")
        #expect(grouped.group_name == nil)

        let direct = try #require(db.search(term: "hello", hours: 24, threshold: 0.6, match: .contains)
            .matches.first { $0.rowid == 1 })
        #expect(direct.is_group == false)
        #expect(direct.chat_identifier == "+12125550100")
    }

    /// A chat.db that cannot answer "which chat is this message in?" degrades to nulls rather
    /// than failing the read outright — the posture the attachment join already takes.
    @Test func missingChatJoinYieldsNullChatIdentity() throws {
        let fx = try ChatFixture()
        try fx.exec("DROP TABLE chat_message_join;")
        var db = try makeDB(fx, book: friendBook)
        let msgs = db.recent(hours: 24, handleRowIds: nil, limit: 100)

        #expect(msgs.count == 9, "the read still succeeds")
        #expect(msgs.allSatisfy { $0.chat_identifier == nil && $0.chat_guid == nil && !$0.is_group })
        // …and `--direct-only` cannot silently swallow the whole store when the schema is the
        // thing that is missing: nothing is KNOWN to be a group, so nothing is excluded.
        #expect(db.recent(hours: 24, handleRowIds: nil, limit: 100, directOnly: true).count == 9)
    }

    /// The guard both `--direct-only` and the identity fields hang off must be the SAME one.
    ///
    /// `missingChatJoinYieldsNullChatIdentity` above cannot prove this: it drops the whole
    /// `chat_message_join` table, which every candidate guard rejects identically. This case
    /// keeps the join table and removes only `chat.style`, which is exactly where the two guards
    /// disagree — and under the weaker one `directOnlyPredicate` referenced a column that no
    /// longer exists, SQLite failed the whole statement, `try?` swallowed it, and
    /// `recent(directOnly:)` returned ZERO rows while reporting nothing wrong.
    @Test func directOnlyIsGatedOnTheSameCapabilityAsTheIdentityFields() throws {
        let fx = try ChatFixture()
        try fx.exec("""
            DROP TABLE chat;
            CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
                room_name TEXT, guid TEXT, service_name TEXT, group_id TEXT);
            INSERT INTO chat (ROWID, chat_identifier, display_name, room_name, guid, service_name, group_id)
            VALUES (1,'chat999','Test Group','chat999','iMessage;+;chat999','iMessage','G1');
            """)
        var db = try makeDB(fx, book: friendBook)

        let unfiltered = db.recent(hours: 24, handleRowIds: nil, limit: 100).map(\.rowid)
        #expect(unfiltered == [1, 2, 3, 4, 5, 6, 8, 9, 10], "precondition: the read still works")
        // The store cannot classify a chat, so nothing is KNOWN to be a group and nothing is
        // excluded. Returning [] here is the regression this pins.
        #expect(db.recent(hours: 24, handleRowIds: nil, limit: 100, directOnly: true).map(\.rowid)
            == unfiltered)
        #expect(db.canIdentifyChats() == false)
        // …and the fields degrade in step with the filter, rather than one working alone.
        #expect(db.recent(hours: 24, handleRowIds: nil, limit: 100)
            .allSatisfy { $0.chat_identifier == nil && !$0.is_group })
    }

    // MARK: - --direct-only

    @Test func recentDirectOnlyExcludesGroupChatMessages() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        let all = db.recent(hours: 24, handleRowIds: nil, limit: 100).map(\.rowid)
        let direct = db.recent(hours: 24, handleRowIds: nil, limit: 100, directOnly: true).map(\.rowid)

        #expect(all == [1, 2, 3, 4, 5, 6, 8, 9, 10])
        // 4 and 5 are the two group-chat messages; 3 has no chat row and is NOT a group, so it
        // survives — the filter drops group chats, not "everything it cannot classify".
        #expect(direct == [1, 2, 3, 6, 8, 9, 10])
    }

    /// The filter runs in SQL, before `LIMIT`, so a caller asking for N direct messages gets N —
    /// not N minus however many group messages happened to be newer.
    @Test func recentDirectOnlyFillsTheRequestedLimit() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        #expect(db.recent(hours: 24, handleRowIds: nil, limit: 4, directOnly: true).map(\.rowid)
            == [1, 2, 3, 6])
        // Same limit unfiltered stops at 4, proving the group rows really were in the way.
        #expect(db.recent(hours: 24, handleRowIds: nil, limit: 4).map(\.rowid) == [1, 2, 3, 4])
    }

    /// `--direct-only` composes with the handle filter rather than replacing it. The two
    /// clauses are built into one WHERE, and the handle filter is the one carrying positional
    /// binds — so a mistake here shows up as wrong rows, not as a compile error.
    @Test func recentDirectOnlyComposesWithTheHandleFilter() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        // Handle 2's only message is the group one, so the two filters together match nothing…
        #expect(db.recent(hours: 24, handleRowIds: [2], limit: 100).map(\.rowid) == [4])
        #expect(db.recent(hours: 24, handleRowIds: [2], limit: 100, directOnly: true).isEmpty)
        // …while handle 1's messages are all 1:1 and survive both.
        #expect(db.recent(hours: 24, handleRowIds: [1], limit: 100, directOnly: true).map(\.rowid)
            == [1, 2, 3, 6, 8, 9, 10])
    }

    @Test func searchDirectOnlyExcludesGroupChatMessages() throws {
        let fx = try ChatFixture()
        var db = try makeDB(fx, book: friendBook)
        #expect(db.search(term: "error", hours: 24, threshold: 0.6, match: .contains)
            .matches.contains { $0.rowid == 5 })
        #expect(db.search(term: "error", hours: 24, threshold: 0.6, match: .contains, directOnly: true)
            .matches.isEmpty)
        // Positive control: a 1:1 hit is untouched by the flag.
        #expect(db.search(term: "hello", hours: 24, threshold: 0.6, match: .contains, directOnly: true)
            .matches.map(\.rowid) == [1])
    }

    // MARK: - chats: activity, participants, filters

    @Test func namedChatsCarryLastActivityAndParticipants() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        let chats = db.namedChats()

        let group = try #require(chats.first { $0.chat_identifier == "chat999" })
        // Message 4 is the group's only message, so it is the newest one.
        #expect(group.last_activity_timestamp == fx.base - 300)
        #expect(group.last_activity == MessageTime.date(fromRaw: fx.base - 300))
        #expect(group.participants == ["+12125550101", "+12125550102"])  // handle-ROWID order

        // A named chat with no messages and no recorded members: nulls and an EMPTY array,
        // never a missing value.
        let quiet = try #require(chats.first { $0.chat_identifier == "chat888" })
        #expect(quiet.last_activity == nil)
        #expect(quiet.last_activity_timestamp == nil)
        #expect(quiet.participants.isEmpty)
    }

    @Test func namedChatsNameFilterIsCaseInsensitiveSubstring() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        #expect(db.namedChats(nameFilter: "oTHer").map(\.display_name) == ["Other Group"])
        #expect(db.namedChats(nameFilter: "group").map(\.display_name) == ["Test Group", "Other Group"])
        #expect(db.namedChats(nameFilter: "nothing-matches-this").isEmpty)
        // An empty filter is not a filter — it must not silently match nothing.
        #expect(db.namedChats(nameFilter: "").count == 2)
    }

    @Test func namedChatsLimitCapsResultsWithoutReordering() throws {
        let fx = try ChatFixture()
        let db = try makeDB(fx, book: friendBook)
        #expect(db.namedChats(limit: 1).map(\.display_name) == ["Test Group"])
        #expect(db.namedChats(limit: 10).count == 2)
        // The limit applies AFTER the name filter, not to the pre-filter row set.
        #expect(db.namedChats(nameFilter: "group", limit: 1).map(\.display_name) == ["Test Group"])
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
