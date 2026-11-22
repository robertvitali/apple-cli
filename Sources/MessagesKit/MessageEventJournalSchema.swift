import Foundation
import SQLite3

/// Version-one on-disk format. The writer creates the same definitions the reader verifies.
enum MessageEventJournalFormat {
    static let applicationID: Int64 = 1094927702
    static let metadata = """
        CREATE TABLE meta(
         id INTEGER PRIMARY KEY CHECK(id=1),
         format INTEGER NOT NULL CHECK(typeof(format)='integer' AND format=1),
         initialized INTEGER NOT NULL CHECK(typeof(initialized)='integer' AND initialized IN(0,1)),
         stream_id BLOB NOT NULL CHECK(typeof(stream_id)='blob' AND length(stream_id)=36),
         source_epoch BLOB NOT NULL CHECK(typeof(source_epoch)='blob' AND length(source_epoch)=36),
         filter_bytes BLOB NOT NULL CHECK(typeof(filter_bytes)='blob' AND length(filter_bytes) BETWEEN 6 AND 263174),
         filter_digest BLOB NOT NULL CHECK(typeof(filter_digest)='blob' AND length(filter_digest)=32),
         source_identity BLOB NOT NULL CHECK(typeof(source_identity)='blob' AND length(source_identity)=29),
         schema_digest BLOB NOT NULL CHECK(typeof(schema_digest)='blob' AND length(schema_digest)=32),
         generation INTEGER NOT NULL CHECK(typeof(generation)='integer' AND generation>=0),
         head INTEGER NOT NULL CHECK(typeof(head)='integer' AND head>=0),
         state_digest BLOB NOT NULL CHECK(typeof(state_digest)='blob' AND length(state_digest)=32),
         CHECK((initialized=0 AND generation=0 AND head=0) OR (initialized=1 AND generation>=1 AND head>=0))
        )
        """
    static let baseline = """
        CREATE TABLE baseline(
         id INTEGER PRIMARY KEY CHECK(id>0),
         chat_guid BLOB NOT NULL CHECK(typeof(chat_guid)='blob' AND length(chat_guid) BETWEEN 1 AND 1024),
         message_guid BLOB NOT NULL CHECK(typeof(message_guid)='blob' AND length(message_guid) BETWEEN 1 AND 1024),
         message_rowid INTEGER NOT NULL CHECK(typeof(message_rowid)='integer' AND message_rowid>0),
         chat_rowid INTEGER NOT NULL CHECK(typeof(chat_rowid)='integer' AND chat_rowid>0),
         component_hashes BLOB NOT NULL CHECK(typeof(component_hashes)='blob' AND length(component_hashes)=256),
         availability BLOB NOT NULL CHECK(typeof(availability)='blob' AND length(availability)=8),
         summary_facets BLOB NOT NULL CHECK(typeof(summary_facets)='blob' AND length(summary_facets)=100),
         projection BLOB NOT NULL CHECK(typeof(projection)='blob' AND length(projection) BETWEEN 1 AND 65536),
         UNIQUE(chat_guid,message_guid)
        )
        """
    static let locator = """
        CREATE INDEX baseline_locator ON baseline(message_rowid,chat_rowid)
        """
    static let events = """
        CREATE TABLE events(
         sequence INTEGER PRIMARY KEY CHECK(sequence>0),
         payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 65536)
        )
        """
    static let stagingBody = "seen(id INTEGER PRIMARY KEY, changes INTEGER NOT NULL CHECK(changes BETWEEN 0 AND 1023), attachment_seen INTEGER NOT NULL CHECK(attachment_seen IN (0,1)))"
    static let createStaging = "CREATE TEMP TABLE " + stagingBody
    static let createMain = ["PRAGMA application_id=\(applicationID)", "PRAGMA user_version=1",
                             metadata, baseline, locator, events]
}

/// Uses the caller's authorized prepare/step functions on one leased connection.
/// Call inside the catalog budget and the transaction that will use the checked schema.
struct MessageEventJournalSchema {
    enum Failure: Error, Equatable { case uninitialized, schemaMismatch, transactionRequired, sqliteCode(Int32) }

    let database: OpaquePointer
    let prepare: (OpaquePointer, String, inout OpaquePointer?) -> Int32
    let step: (OpaquePointer) -> Int32

    private struct Object: Hashable {
        let kind, name, table: Data
        let sql: Data?

        init(kind: Data, name: Data, table: Data, sql: Data?) {
            self.kind = kind
            self.name = name
            self.table = table
            self.sql = sql
        }

        init(_ kind: String, _ name: String, _ table: String, _ sql: String?) {
            self.init(kind: Data(kind.utf8), name: Data(name.utf8), table: Data(table.utf8), sql: sql.map { Data($0.utf8) })
        }
    }

    private static let mainObjects: Set<Object> = [
        Object("table", "meta", "meta", MessageEventJournalFormat.metadata),
        Object("table", "baseline", "baseline", MessageEventJournalFormat.baseline),
        Object("index", "sqlite_autoindex_baseline_1", "baseline", nil),
        Object("index", "baseline_locator", "baseline", MessageEventJournalFormat.locator),
        Object("table", "events", "events", MessageEventJournalFormat.events)
    ]
    private static let stagingObjects: Set<Object> = [
        Object("table", "seen", "seen", "CREATE TABLE " + MessageEventJournalFormat.stagingBody)
    ]

    func validateMain() throws {
        try inventory("SELECT type,name,tbl_name,sql,rootpage FROM main.sqlite_schema LIMIT 6",
                      expected: Self.mainObjects, distinguishEmpty: true)
        try checkInteger("PRAGMA main.application_id", MessageEventJournalFormat.applicationID)
        try checkInteger("PRAGMA main.user_version", 1)
        try checkInteger("PRAGMA main.page_size", 4096)

        // SQLite inherits a suggested page count from the file header. Reduce it
        // before scanning journal data. cache_size is advisory and connection-local.
        let cache = try integerValue("PRAGMA main.cache_size")
        if cache > 512 || cache < -2048 {
            try rows("PRAGMA main.cache_size=-2048") { _ in throw Failure.schemaMismatch }
            try checkInteger("PRAGMA main.cache_size", -2048)
        }
    }

    func requireEmptyTemp() throws {
        try rows("SELECT 1 FROM temp.sqlite_schema LIMIT 1") { _ in throw Failure.schemaMismatch }
    }

    func validateStaging() throws {
        try inventory("SELECT type,name,tbl_name,sql,rootpage FROM temp.sqlite_schema LIMIT 2",
                      expected: Self.stagingObjects, distinguishEmpty: false)
        try checkInteger("PRAGMA temp_store", 2)
        try checkInteger("PRAGMA temp.page_size", 4096)
        try checkInteger("PRAGMA temp.max_page_count", 4096)
        try checkInteger("PRAGMA main.max_page_count", 131072)
    }

    func rows(_ sql: String, visit: (OpaquePointer) throws -> Void) throws {
        guard sqlite3_get_autocommit(database) == 0 else { throw Failure.transactionRequired }
        try withStatement(sql) { statement in
            while true {
                switch step(statement) {
                case SQLITE_DONE: return
                case SQLITE_ROW: try visit(statement)
                case let error: throw Failure.sqliteCode(error)
                }
            }
        }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        let code = prepare(database, sql, &raw)
        defer { sqlite3_finalize(raw) }
        guard code == SQLITE_OK else { throw Failure.sqliteCode(code) }
        guard let raw else { throw Failure.schemaMismatch }
        return try body(raw)
    }

    private func checkInteger(_ sql: String, _ expected: Int64) throws {
        guard try integerValue(sql) == expected else { throw Failure.schemaMismatch }
    }

    private func integerValue(_ sql: String) throws -> Int64 {
        var value: Int64?
        try rows(sql) { row in
            guard value == nil, sqlite3_column_count(row) == 1,
                  sqlite3_column_type(row, 0) == SQLITE_INTEGER else { throw Failure.schemaMismatch }
            value = sqlite3_column_int64(row, 0)
        }
        guard let value else { throw Failure.schemaMismatch }
        return value
    }

    private func inventory(_ sql: String, expected: Set<Object>, distinguishEmpty: Bool) throws {
        var missing = expected
        var roots = Set<Int64>()
        try rows(sql) { row in
            guard !missing.isEmpty else { throw Failure.schemaMismatch }
            let ddl = sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : try text(row, 3, maxBytes: 4096)
            let object = try Object(kind: text(row, 0), name: text(row, 1), table: text(row, 2), sql: ddl)
            guard missing.remove(object) != nil, sqlite3_column_type(row, 4) == SQLITE_INTEGER else {
                throw Failure.schemaMismatch
            }
            let root = sqlite3_column_int64(row, 4)
            guard root > 1, roots.insert(root).inserted else { throw Failure.schemaMismatch }
        }
        if distinguishEmpty && roots.isEmpty { throw Failure.uninitialized }
        guard missing.isEmpty else { throw Failure.schemaMismatch }
    }

    private func text(_ row: OpaquePointer, _ column: Int32, maxBytes: Int = 128) throws -> Data {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT else { throw Failure.schemaMismatch }
        guard let utf8 = sqlite3_column_text(row, column) else { throw Failure.sqliteCode(SQLITE_NOMEM) }
        let count = Int(sqlite3_column_bytes(row, column))
        guard (1...maxBytes).contains(count) else { throw Failure.schemaMismatch }
        return Data(bytes: utf8, count: count)
    }
}
