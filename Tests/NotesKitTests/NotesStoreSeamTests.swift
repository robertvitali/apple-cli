import Foundation
import Compression
import SQLite3
import Testing
import TestSupport
@testable import NotesKit
@testable import AppleKit

// `NotesStore`'s own logic, exercised through the `dbPath` seam.
//
// NOTHING HERE OPENS THE OPERATOR'S NOTES DATABASE. Three substitutes cover the branches:
//
//   * a path that does not exist  → the "store missing / no Full Disk Access" branches;
//   * a path that exists but is NOT a database (this source file) → the SQLite failure branches.
//     `SQLiteReader` snapshots it and `sqlite3_prepare` rejects it, which is exactly the shape a
//     corrupt or unreadable store produces;
//   * a SYNTHETIC `NoteStore.sqlite` built under `ScratchDirs` (`NoteStoreFixture`, below) → the
//     SQLite SUCCESS paths, which the first two cannot reach at all. This is the use
//     `LiveNotesStore.dbPath` is documented as existing for.
//
// The public no-argument wrappers are reached only with a MALFORMED note id, which short-circuits
// at the primary-key guard before any filesystem access — so even those never stat, open, or read
// the real store.
//
// The protobuf walk is ALSO tested directly against synthesized bytes rather than through a
// database: `parseChecklist` takes ALREADY-INFLATED bytes, so a fixture built here exercises the
// identical code path the SQLite read feeds, with no store and no gzip round trip. The fixture-store
// suite then drives those same bytes through gzip and SQLite so the seam between them is covered too.

@Suite("NotesStore — path seam, id parsing, and hex decoding")
struct NotesStorePathSeamTests {
    private let scratch = ScratchDirs("notes-store-seam")

    /// An existing file that is emphatically not a SQLite database. Only ever stat'd and opened
    /// read-only, never written.
    private var notADatabase: String { #filePath }
    /// A path under an existing directory that does not exist. It lives under the suite's scratch
    /// root rather than beside this source file: nothing creates it today, but an unignored path
    /// inside the working tree is the staging half of the shape AGENTS.md warns about, and the
    /// scratch root is already here and is reclaimed by `ScratchDirs.deinit`.
    private let missingStore: String

    init() throws {
        missingStore = try scratch.directory()
            .appendingPathComponent("apple-cli-test-no-such-store.sqlite").path
    }

    @Test func primaryKeyExtractsOnlyTheTrailingCoreDataKey() {
        #expect(NotesStore.primaryKey(from: fixtureNoteID(42)) == 42)
        #expect(NotesStore.primaryKey(from: "x-coredata://UUID/ICNote/p0") == 0)
        #expect(NotesStore.primaryKey(from: "x-coredata://UUID/ICNote/pNaN") == nil)
        #expect(NotesStore.primaryKey(from: "temp-1-2") == nil)
        #expect(NotesStore.primaryKey(from: "") == nil)
    }

    @Test func hexDecodingHandlesOddAndInvalidInput() {
        #expect(NotesStore.hexToBytes("00FF10") == [0x00, 0xFF, 0x10])
        #expect(NotesStore.hexToBytes("") == [])
        // A trailing half-byte is decoded as its own nibble rather than crashing or being dropped.
        #expect(NotesStore.hexToBytes("FFA") == [0xFF, 0x0A])
        // A non-hex pair is skipped, not substituted.
        #expect(NotesStore.hexToBytes("ZZ01") == [0x01])
    }

    @Test func walPathIsDerivedTheSameWayAtAnyPath() {
        // Only the parameterized form is asserted: `NotesStore.walPath` is DEFINED as
        // `dbPath + "-wal"`, so pinning it against that same expression is `A == A` after
        // inlining and can never fail.
        #expect(NotesStore.walPath(for: "/some/store.sqlite") == "/some/store.sqlite-wal")
    }

    @Test func existenceIsAskedOfThePathThatWasHandedIn() {
        // Likewise `dbExists` is defined as `exists(at: dbPath)`; the load-bearing half is
        // `exists(at:)` answering about the two fixtures below.
        #expect(NotesStore.exists(at: notADatabase))
        #expect(NotesStore.exists(at: missingStore) == false)
    }

    // MARK: noteLink

    @Test func noteLinkReturnsNilForEveryFailureTheOracleSwallows() {
        // Malformed id — short-circuits before any filesystem access, which is also what makes the
        // public wrapper safe to call here.
        #expect(NotesStore.noteLink(noteId: "not-an-id") == nil)
        #expect(NotesStore.noteLink(noteId: "not-an-id", dbPath: notADatabase) == nil)
        // Store absent.
        #expect(NotesStore.noteLink(noteId: fixtureNoteID(1), dbPath: missingStore) == nil)
        // Store present but unreadable as SQLite — the `catch` returns nil rather than throwing,
        // because the caller falls back to AppleScript.
        #expect(NotesStore.noteLink(noteId: fixtureNoteID(1), dbPath: notADatabase) == nil)
    }

    // MARK: checklistItems

    @Test func checklistReportsInvalidIdWithTheOracleWording() {
        let outcome = NotesStore.checklistItems(noteId: "not-an-id")
        #expect(outcome.error == .invalidId)
        #expect(outcome.items == nil)
        #expect(outcome.message?.contains("Expected format: x-coredata://UUID/ICNote/pNNN") == true)
    }

    @Test func checklistReportsMissingFullDiskAccessWhenTheStoreIsAbsent() {
        let outcome = NotesStore.checklistItems(noteId: fixtureNoteID(1), dbPath: missingStore)
        #expect(outcome.error == .noFDA)
        #expect(outcome.message == NotesStore.fdaChecklistMessage)
        #expect(NotesStore.fdaChecklistMessage.contains(NotesStore.fdaGuideURL))
    }

    @Test func checklistReportsAParseErrorWhenTheStoreCannotBeQueried() {
        let outcome = NotesStore.checklistItems(noteId: fixtureNoteID(1), dbPath: notADatabase)
        #expect(outcome.error == .parseError)
        #expect(outcome.message == "Failed to query NoteStore database.")
    }

    // MARK: metadata

    @Test func metadataReportsInvalidIdAndMissingStore() {
        let invalid = NotesStore.metadata(noteId: "not-an-id")
        #expect(invalid.error == .invalidId)
        #expect(invalid.metadata == nil)

        let absent = NotesStore.metadata(noteId: fixtureNoteID(1), dbPath: missingStore)
        #expect(absent.error == .noFDA)
        #expect(absent.message == NotesStore.fdaMetadataMessage)
        #expect(NotesStore.fdaMetadataMessage.contains("read note metadata"))
    }

    @Test func metadataReportsAQueryErrorWhenTheStoreCannotBeRead() {
        let outcome = NotesStore.metadata(noteId: fixtureNoteID(1), dbPath: notADatabase)
        #expect(outcome.error == .queryError)
        #expect(outcome.message == "Failed to read note metadata.")
    }

    @Test func theMetadataColumnMapKeepsTheWireKeysAndTheirTypes() {
        // The keys are the apple-cli wire keys, and `isBool` decides `set(_:bool:)` vs
        // `set(_:text:)` — a wrong flag would silently emit a boolean column as a string.
        let byKey = Dictionary(uniqueKeysWithValues: NotesStore.metadataColumns.map { ($0.key, $0) })
        #expect(byKey["pinned"]?.column == "ZISPINNED")
        #expect(byKey["pinned"]?.isBool == true)
        #expect(byKey["snippet"]?.column == "ZSNIPPET")
        #expect(byKey["snippet"]?.isBool == false)
        #expect(byKey["password_protected"]?.isBool == true)
        #expect(NotesStore.metadataColumns.count == 9)
    }

    @Test func metadataSettersIgnoreUnknownKeys() {
        var md = NotesMetadata()
        md.set("pinned", bool: true)
        md.set("snippet", text: "apple-cli-test snippet")
        md.set("not_a_column", bool: true)
        md.set("not_a_column", text: "ignored")
        #expect(md.pinned == true)
        #expect(md.snippet == "apple-cli-test snippet")
        #expect(md.password_hint == nil)
    }

    // MARK: syncStatus

    @Test func syncStatusReportsAMissingDatabase() {
        let status = NotesStore.syncStatus(dbPath: missingStore)
        #expect(status.error == "Notes database not found")
        #expect(status.sync_detected == false)
        #expect(status.seconds_since_last_change == nil)
    }

    @Test func syncStatusDegradesToZeroPendingWhenTheQueryFails() {
        // The store file exists but is not a database: the count query fails and is swallowed, and
        // the WAL-derived half still stands (there is no `-wal` beside this file, so it is nil).
        let status = NotesStore.syncStatus(dbPath: notADatabase)
        #expect(status.pending_upload == 0)
        #expect(status.error == nil)
        #expect(status.sync_detected == false)
    }

    @Test func syncStatusReadsTheWalTimestampWhenASidecarIsPresent() throws {
        // `ScratchDirs` owns the directory and reclaims it when this test's suite instance is
        // released, so the pair never outlives the run.
        let store = try scratch.directory().appendingPathComponent("NoteStore.sqlite").path
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: store))
        try Data().write(to: URL(fileURLWithPath: NotesStore.walPath(for: store)))

        let status = NotesStore.syncStatus(dbPath: store)

        let seconds = try #require(status.seconds_since_last_change,
                                   "a present -wal sidecar must yield a seconds-since-change reading")
        #expect(seconds >= 0)
        #expect(status.recent_activity == (Double(seconds) < NotesStore.recentActivityThresholdSeconds))
    }

    // MARK: hasFDA

    @Test func fullDiskAccessProbeAnswersAboutThePathItWasGiven() {
        #expect(NotesStore.hasFDA(dbPath: missingStore) == false)
        #expect(NotesStore.hasFDA(dbPath: notADatabase) == true, "an openable file reads as granted")
    }

    // MARK: LiveNotesStore forwarding

    @Test func liveStoreForwardsEveryCallToTheConfiguredPath() {
        let store = LiveNotesStore(dbPath: missingStore)
        #expect(store.dbExists == false)
        #expect(store.hasFDA() == false)
        #expect(store.noteLink(noteId: fixtureNoteID(1)) == nil)
        #expect(store.checklistItems(noteId: fixtureNoteID(1)).error == .noFDA)
        #expect(store.metadata(noteId: fixtureNoteID(1)).error == .noFDA)
        #expect(store.syncStatus().error == "Notes database not found")
    }

    @Test func theDefaultLiveStorePointsAtTheRealNoteStorePath() {
        // The production default must remain the live store — the seam is for the logic tier only,
        // and nothing reachable from argv or the environment may repoint it.
        #expect(LiveNotesStore().dbPath == NotesStore.dbPath)
        #expect(NotesStore.dbPath.hasSuffix("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"))
    }

    @Test func theLiveWriteEnvNamesTheRealVariablesAndDefersTheSandboxLabel() {
        // The write-gate twin of the store pin above, and for the same reason: `NotesWriteEnv.live`
        // is the ONE place naming which environment variables the shipped CLI honors on every Notes
        // write, and every write TEST routes through `pinnedWriteEnv()` instead — so without this,
        // nothing in the repository observes `.live` at all. Repointing it at test-owned names (the
        // shape someone reaches for to quiet a flaky test) would silently stop `APPLE_DRY_RUN=1`
        // forcing preview and stop `APPLE_TEST_MODE=1` engaging the sandbox, with the suite green.
        #expect(NotesWriteEnv.live.testModeVar == TestMode.testModeVar)
        #expect(NotesWriteEnv.live.dryRunVar == TestMode.dryRunVar)
        // nil, NOT a literal: it defers to `TestMode.sandboxPrefix`, so `APPLE_TEST_SANDBOX` keeps
        // working. A literal `""` here would additionally vacate every label check downstream,
        // because `name.hasPrefix("")` is always true.
        #expect(NotesWriteEnv.live.sandboxPrefix == nil)
    }
}

/// Minimal Notes-protobuf encoder (wire format only — no dependency, no fixture file).
///
/// Shared by the two suites below rather than private to either: the walk suite feeds these bytes
/// to `parseChecklist` DIRECTLY, and the fixture-store suite gzips the same bytes into a synthetic
/// `ZICNOTEDATA.ZDATA` blob so the SQLite read path produces them. One encoder means the two tiers
/// cannot disagree about what a Notes document looks like.
enum NotesProtobufFixture {

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func varintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        varint(UInt64(number << 3 | 0)) + varint(value)
    }

    static func lengthDelimited(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload
    }

    static func stringField(_ number: Int, _ text: String) -> [UInt8] {
        lengthDelimited(number, Array(text.utf8))
    }

    /// One attribute run: `length`, and (optionally) a paragraph style that marks it a checklist.
    static func run(length: Int, checklist: Bool, done: Bool) -> [UInt8] {
        var fields = varintField(1, UInt64(length))
        if checklist {
            var style = varintField(1, NotesStore.checklistStyleType)
            style += lengthDelimited(5, varintField(2, done ? 1 : 0))
            fields += lengthDelimited(2, style)
        }
        return fields
    }

    /// The document envelope the walk expects: doc.2 → wrapper.3 → body{ 2: text, 5*: runs }.
    static func document(text: String, runs: [[UInt8]]) -> [UInt8] {
        var body = stringField(2, text)
        for r in runs { body += lengthDelimited(5, r) }
        let wrapper = lengthDelimited(3, body)
        return lengthDelimited(2, wrapper)
    }
}

@Suite("NotesStore — checklist protobuf walk")
struct NotesStoreChecklistProtobufTests {

    // Thin forwarders onto the shared encoder above, so these tests keep reading as they did.
    private func varintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        NotesProtobufFixture.varintField(number, value)
    }
    private func lengthDelimited(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        NotesProtobufFixture.lengthDelimited(number, payload)
    }
    private func stringField(_ number: Int, _ text: String) -> [UInt8] {
        NotesProtobufFixture.stringField(number, text)
    }
    private func run(length: Int, checklist: Bool, done: Bool) -> [UInt8] {
        NotesProtobufFixture.run(length: length, checklist: checklist, done: done)
    }
    private func document(text: String, runs: [[UInt8]]) -> [UInt8] {
        NotesProtobufFixture.document(text: text, runs: runs)
    }

    @Test func checklistRunsArePairedWithTheirTextLines() throws {
        let bytes = document(text: "buy milk\nwalk dog\nplain line", runs: [
            run(length: 9, checklist: true, done: true),   // "buy milk" + newline
            run(length: 9, checklist: true, done: false),  // "walk dog" + newline
            run(length: 10, checklist: false, done: false),
        ])

        let items = try #require(NotesStore.parseChecklist(bytes))

        #expect(items == [NotesStore.ChecklistItem(text: "buy milk", done: true),
                          NotesStore.ChecklistItem(text: "walk dog", done: false)])
    }

    @Test func aRunWithNoChecklistStyleIsNotAnItem() throws {
        let bytes = document(text: "just a paragraph", runs: [
            run(length: 16, checklist: false, done: false),
        ])

        let items = try #require(NotesStore.parseChecklist(bytes))
        #expect(items.isEmpty)
    }

    @Test func aChecklistRunWithNoDoneFieldDefaultsToNotDone() throws {
        // paragraph_style present with the checklist style type but no checklist sub-message.
        var style = varintField(1, NotesStore.checklistStyleType)
        style += [] // no field 5
        let runFields = varintField(1, 5) + lengthDelimited(2, style)
        let bytes = document(text: "task", runs: [runFields])

        let items = try #require(NotesStore.parseChecklist(bytes))
        #expect(items == [NotesStore.ChecklistItem(text: "task", done: false)])
    }

    @Test func measuringRunOffsetsInUtf16CodeUnitsKeepsNonBmpLinesAligned() throws {
        // "🙂ok" is 3 graphemes but 4 UTF-16 code units. Measuring in graphemes would mis-map the
        // SECOND run onto the first line — the recurring parity trap in this port.
        let text = "🙂ok\nsecond"
        let bytes = document(text: text, runs: [
            run(length: 5, checklist: true, done: false),  // 4 units + newline
            run(length: 6, checklist: true, done: true),
        ])

        let items = try #require(NotesStore.parseChecklist(bytes))
        #expect(items == [NotesStore.ChecklistItem(text: "🙂ok", done: false),
                          NotesStore.ChecklistItem(text: "second", done: true)])
    }

    @Test func aMalformedOrEmptyDocumentYieldsNil() {
        #expect(NotesStore.parseChecklist([]) == nil)
        // Right envelope, no attribute runs at all.
        #expect(NotesStore.parseChecklist(document(text: "text", runs: [])) == nil)
        // Wrong envelope: the note-body field is missing.
        #expect(NotesStore.parseChecklist(lengthDelimited(2, stringField(9, "x"))) == nil)
    }
}

// MARK: - Synthetic NoteStore.sqlite

/// Builds a throwaway `NoteStore.sqlite` carrying only the tables and columns `NotesStore` queries.
///
/// WHY THIS EXISTS: `LiveNotesStore`'s `dbPath` parameter is documented as being there "only so the
/// logic tier can point the REAL query code at a synthetic fixture database", but every test above
/// points it at a NON-database — which covers the failure branches and leaves every SQLite SUCCESS
/// path (the deep-link construction, the hex → gunzip → protobuf pipeline, the metadata column
/// selection and row mapping, `presentColumns`, the pending-upload count) unexercised. These
/// fixtures are what make that documented use real.
///
/// NO REAL DATA REACHES THIS FILE. Every value is invented: `apple-cli-test`-prefixed titles, an
/// all-digits identifier UUID, and protobuf bodies assembled byte-by-byte by `NotesProtobufFixture`.
/// The database is created under `ScratchDirs` and dies with the suite instance; nothing here
/// stats, opens, or reads the operator's `~/Library/Group Containers` store.
enum NoteStoreFixture {

    struct BuildError: Error, CustomStringConvertible {
        let description: String
    }

    /// The `ZICCLOUDSYNCINGOBJECT` columns `NotesStore` reads: the join/identity pair, the cloud
    /// state foreign key `syncStatus` correlates on, and the nine metadata columns. Real Notes
    /// stores carry hundreds more; only these are load-bearing here, and a fixture that declares
    /// exactly the read set is also what makes the `presentColumns` filtering visible when a
    /// narrower fixture omits some of them.
    static let fullSyncingObjectSchema = """
        Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZCLOUDSTATE INTEGER,
        ZISPINNED INTEGER, ZHASCHECKLIST INTEGER, ZHASCHECKLISTINPROGRESS INTEGER,
        ZISRECOVERINGFROMTRASH INTEGER, ZISPASSWORDPROTECTED INTEGER,
        ZPASSWORDHINT TEXT, ZSNIPPET TEXT, ZWIDGETSNIPPET TEXT, ZSMARTFOLDERQUERYJSON TEXT
        """

    /// Create a store at `path` with `ZICCLOUDSYNCINGOBJECT` declared as `syncingObjectSchema`,
    /// plus the two side tables, then run `rows`.
    static func build(at path: String, syncingObjectSchema: String = fullSyncingObjectSchema,
                      rows: [String] = []) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close(db)
            throw BuildError(description: message)
        }
        defer { sqlite3_close(handle) }

        let ddl = [
            "CREATE TABLE ZICCLOUDSYNCINGOBJECT (\(syncingObjectSchema));",
            "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB);",
            """
            CREATE TABLE ZICCLOUDSTATE (Z_PK INTEGER PRIMARY KEY,
                ZCURRENTLOCALVERSION INTEGER, ZLATESTVERSIONSYNCEDTOCLOUD INTEGER);
            """,
        ]
        for statement in ddl + rows {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, statement, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
                sqlite3_free(error)
                throw BuildError(description: "\(message) — while running: \(statement)")
            }
        }
    }

    /// A SQLite blob literal (`X'…'`) for `bytes`. The production read is `hex(nd.ZDATA)`, so a hex
    /// literal in and a hex string out is the same representation on both sides — no blob binding
    /// needed, and the fixture SQL stays readable.
    static func blobLiteral(_ bytes: [UInt8]) -> String {
        "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
    }

    /// Wrap raw DEFLATE output in a real RFC-1952 gzip container, the way Apple Notes stores
    /// `ZDATA`. `Gzip.inflate` parses the header itself and hands the body to
    /// `compression_decode_buffer(COMPRESSION_ZLIB)` — Apple's "ZLIB" is raw DEFLATE — so the
    /// encoder below is that call's exact inverse. The trailer's ISIZE is load-bearing (it sizes
    /// the inflate buffer); the CRC32 is written correctly even though `Gzip.inflate` does not
    /// verify it, so the fixture is a stream any gzip tool would also accept.
    static func gzip(_ raw: [UInt8]) throws -> [UInt8] {
        let capacity = raw.count + 1024
        var deflated = [UInt8](repeating: 0, count: capacity)
        let written = raw.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return 0 }
            return deflated.withUnsafeMutableBufferPointer { dst -> Int in
                guard let out = dst.baseAddress else { return 0 }
                return compression_encode_buffer(out, capacity, base, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw BuildError(description: "deflate produced no output") }

        var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03] // magic, method, no FLG, mtime 0, OS unknown
        out += deflated[0..<written]
        let isize = UInt32(truncatingIfNeeded: raw.count)
        for value in [crc32(raw), isize] {
            out += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                    UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        }
        return out
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

@Suite("NotesStore — the SQLite read paths, against a synthetic fixture store")
struct NotesStoreFixtureQueryTests {
    private let scratch = ScratchDirs("notes-store-fixture")

    /// A synthetic identifier. All-digits rather than hex-looking so it cannot be mistaken for a
    /// value copied out of a real store.
    private static let identifier = "11111111-2222-3333-4444-555555555555"

    private func storePath(_ name: String) throws -> String {
        try scratch.directory().appendingPathComponent(name).path
    }

    // MARK: noteLink

    @Test func noteLinkWrapsTheFetchedIdentifierAsADeepLink() throws {
        let path = try storePath("NoteStore-link.sqlite")
        try NoteStoreFixture.build(at: path, rows: [
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER) VALUES (42, '\(Self.identifier)');",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER) VALUES (43, '');",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER) VALUES (44, NULL);",
        ])

        // The success path: the query runs, the row is found, and the URL is assembled from the
        // FETCHED identifier — the branch every prior store test skipped by pointing at a
        // non-database.
        #expect(NotesStore.noteLink(noteId: fixtureNoteID(42), dbPath: path)
                == "notes://showNote?identifier=\(Self.identifier)")
        // Present but unusable rows return nil rather than a malformed link, because the caller
        // falls back to AppleScript on nil.
        #expect(NotesStore.noteLink(noteId: fixtureNoteID(43), dbPath: path) == nil, "empty identifier")
        #expect(NotesStore.noteLink(noteId: fixtureNoteID(44), dbPath: path) == nil, "null identifier")
        #expect(NotesStore.noteLink(noteId: fixtureNoteID(99), dbPath: path) == nil, "no such row")
    }

    // MARK: checklistItems

    @Test func checklistItemsInflateAndParseTheStoredBlob() throws {
        let document = NotesProtobufFixture.document(
            text: "apple-cli-test buy milk\napple-cli-test walk dog",
            runs: [NotesProtobufFixture.run(length: 24, checklist: true, done: true),
                   NotesProtobufFixture.run(length: 23, checklist: true, done: false)])
        let path = try storePath("NoteStore-checklist.sqlite")
        try NoteStoreFixture.build(at: path, rows: [
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK) VALUES (42);",
            "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES "
                + "(1, 42, \(NoteStoreFixture.blobLiteral(try NoteStoreFixture.gzip(document))));",
        ])

        let outcome = NotesStore.checklistItems(noteId: fixtureNoteID(42), dbPath: path)

        #expect(outcome.error == nil)
        #expect(outcome.items == [NotesStore.ChecklistItem(text: "apple-cli-test buy milk", done: true),
                                  NotesStore.ChecklistItem(text: "apple-cli-test walk dog", done: false)])
    }

    @Test func checklistItemsReportNoChecklistsWhenTheJoinFindsNothingUsable() throws {
        let path = try storePath("NoteStore-checklist-empty.sqlite")
        try NoteStoreFixture.build(at: path, rows: [
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK) VALUES (42);",   // no ZICNOTEDATA row at all
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK) VALUES (43);",
            "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (1, 43, X'');",  // present but empty
        ])

        for pk in [42, 43] {
            let outcome = NotesStore.checklistItems(noteId: fixtureNoteID(pk), dbPath: path)
            #expect(outcome.error == .noChecklists, "pk \(pk)")
            #expect(outcome.message == "No data found for this note in the database.", "pk \(pk)")
        }
    }

    @Test func checklistItemsSeparateAnUndecompressableBlobFromAnUnparseableOne() throws {
        // Two DIFFERENT failures with two different messages, both on the success side of the
        // query: the blob was read, and then either gunzip or the protobuf walk gave up. Only a
        // real stored blob reaches these — every earlier store test failed at the query instead.
        let path = try storePath("NoteStore-checklist-bad.sqlite")
        let notChecklist = NotesProtobufFixture.document(
            text: "apple-cli-test plain paragraph",
            runs: [NotesProtobufFixture.run(length: 30, checklist: false, done: false)])
        try NoteStoreFixture.build(at: path, rows: [
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK) VALUES (42);",
            "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES (1, 42, X'00112233445566778899AABBCCDDEEFF0011');",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK) VALUES (43);",
            "INSERT INTO ZICNOTEDATA (Z_PK, ZNOTE, ZDATA) VALUES "
                + "(2, 43, \(NoteStoreFixture.blobLiteral(try NoteStoreFixture.gzip(notChecklist))));",
        ])

        let notGzip = NotesStore.checklistItems(noteId: fixtureNoteID(42), dbPath: path)
        #expect(notGzip.error == .parseError)
        #expect(notGzip.message == "Failed to decompress note data.")

        let noItems = NotesStore.checklistItems(noteId: fixtureNoteID(43), dbPath: path)
        #expect(noItems.error == .noChecklists)
        #expect(noItems.message == "This note does not contain any checklist items.")
    }

    // MARK: metadata

    @Test func metadataMapsEveryPresentColumnAccordingToItsDeclaredType() throws {
        let path = try storePath("NoteStore-metadata.sqlite")
        try NoteStoreFixture.build(at: path, rows: [
            """
            INSERT INTO ZICCLOUDSYNCINGOBJECT
                (Z_PK, ZISPINNED, ZHASCHECKLIST, ZHASCHECKLISTINPROGRESS, ZISRECOVERINGFROMTRASH,
                 ZISPASSWORDPROTECTED, ZPASSWORDHINT, ZSNIPPET, ZWIDGETSNIPPET, ZSMARTFOLDERQUERYJSON)
                VALUES (42, 1, 0, 1, 0, 0, NULL, 'apple-cli-test snippet', 'apple-cli-test widget', NULL);
            """,
        ])

        let outcome = NotesStore.metadata(noteId: fixtureNoteID(42), dbPath: path)

        #expect(outcome.error == nil)
        let md = try #require(outcome.metadata)
        // 1/0 become true/false — the `isBool` half of the column map, decided by the map and
        // applied here for the first time against a real row.
        #expect(md.pinned == true)
        #expect(md.has_checklist == false)
        #expect(md.has_checklist_in_progress == true)
        #expect(md.recovering_from_trash == false)
        #expect(md.password_protected == false)
        #expect(md.snippet == "apple-cli-test snippet")
        #expect(md.widget_snippet == "apple-cli-test widget")
        // NULL is SKIPPED, not rendered as an empty string or a false — the reference's contract.
        #expect(md.password_hint == nil)
        #expect(md.smart_folder_query == nil)
    }

    @Test func metadataReportsNotFoundWhenTheColumnsExistButTheRowDoesNot() throws {
        let path = try storePath("NoteStore-metadata-missing-row.sqlite")
        try NoteStoreFixture.build(at: path, rows: [
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZISPINNED) VALUES (42, 1);",
        ])

        let outcome = NotesStore.metadata(noteId: fixtureNoteID(99), dbPath: path)

        #expect(outcome.error == .notFound)
        #expect(outcome.message?.contains(fixtureNoteID(99)) == true)
    }

    @Test func metadataSelectsOnlyTheColumnsTheSchemaActuallyHas() throws {
        // Schema drift is the reason `presentColumns` exists: Notes' columns vary by macOS
        // release, and SELECTing an absent one fails the whole query rather than one field. This
        // fixture declares two of the nine, which is a shape no non-database fixture can produce.
        let path = try storePath("NoteStore-metadata-narrow.sqlite")
        try NoteStoreFixture.build(
            at: path,
            syncingObjectSchema: "Z_PK INTEGER PRIMARY KEY, ZISPINNED INTEGER, ZSNIPPET TEXT",
            rows: ["INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZISPINNED, ZSNIPPET) "
                   + "VALUES (42, 1, 'apple-cli-test narrow');"])

        let outcome = NotesStore.metadata(noteId: fixtureNoteID(42), dbPath: path)

        #expect(outcome.error == nil)
        let md = try #require(outcome.metadata)
        #expect(md.pinned == true)
        #expect(md.snippet == "apple-cli-test narrow")
        #expect(md.has_checklist == nil, "an absent column is skipped, not defaulted")
        #expect(md.widget_snippet == nil)
    }

    @Test func metadataReturnsAnEmptyPayloadWhenNoKnownColumnIsPresent() throws {
        // The degenerate end of the same guard: nothing to select, so the read succeeds with an
        // EMPTY metadata object rather than failing or emitting nulls for columns it never asked
        // about. Distinct from `notFound`, and it must not become an error.
        let path = try storePath("NoteStore-metadata-none.sqlite")
        try NoteStoreFixture.build(at: path, syncingObjectSchema: "Z_PK INTEGER PRIMARY KEY",
                                   rows: ["INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK) VALUES (42);"])

        let outcome = NotesStore.metadata(noteId: fixtureNoteID(42), dbPath: path)

        #expect(outcome.error == nil)
        let md = try #require(outcome.metadata)
        #expect(md.pinned == nil)
        #expect(md.snippet == nil)
    }

    // MARK: syncStatus

    @Test func syncStatusCountsPendingUploadsFromTheCloudStateTable() throws {
        let path = try storePath("NoteStore-sync-pending.sqlite")
        try NoteStoreFixture.build(at: path, rows: [
            // Counted: ahead of the cloud, synced version known, and an object references it.
            "INSERT INTO ZICCLOUDSTATE (Z_PK, ZCURRENTLOCALVERSION, ZLATESTVERSIONSYNCEDTOCLOUD) VALUES (1, 5, 3);",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZCLOUDSTATE) VALUES (42, 1);",
            // Not counted: never synced (NULL), so "ahead" is meaningless.
            "INSERT INTO ZICCLOUDSTATE (Z_PK, ZCURRENTLOCALVERSION, ZLATESTVERSIONSYNCEDTOCLOUD) VALUES (2, 5, NULL);",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZCLOUDSTATE) VALUES (43, 2);",
            // Not counted: up to date.
            "INSERT INTO ZICCLOUDSTATE (Z_PK, ZCURRENTLOCALVERSION, ZLATESTVERSIONSYNCEDTOCLOUD) VALUES (3, 3, 3);",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZCLOUDSTATE) VALUES (44, 3);",
            // Not counted: ahead, but no object references this state row.
            "INSERT INTO ZICCLOUDSTATE (Z_PK, ZCURRENTLOCALVERSION, ZLATESTVERSIONSYNCEDTOCLOUD) VALUES (4, 9, 1);",
        ])

        let status = NotesStore.syncStatus(dbPath: path)

        #expect(status.pending_upload == 1, "only the ahead-and-referenced state row counts")
        #expect(status.sync_detected == true)
        #expect(status.warning?.contains("1 item(s) pending upload") == true)
        #expect(status.error == nil)
        // No `-wal` sidecar beside the fixture, so the other half of the signal is absent and the
        // verdict rests on the count alone.
        #expect(status.seconds_since_last_change == nil)
        #expect(status.recent_activity == false)
    }

    @Test func syncStatusIsQuietWhenNothingIsPending() throws {
        let path = try storePath("NoteStore-sync-quiet.sqlite")
        try NoteStoreFixture.build(at: path, rows: [
            "INSERT INTO ZICCLOUDSTATE (Z_PK, ZCURRENTLOCALVERSION, ZLATESTVERSIONSYNCEDTOCLOUD) VALUES (1, 3, 3);",
            "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZCLOUDSTATE) VALUES (42, 1);",
        ])

        let status = NotesStore.syncStatus(dbPath: path)

        #expect(status.pending_upload == 0)
        #expect(status.sync_detected == false)
        #expect(status.warning == nil)
    }
}
