import SQLite3
import Testing
@testable import MessagesKit

struct MessageEventJournalSchemaTests {
    private typealias Schema = MessageEventJournalSchema

    private func withDatabase(_ body: (Schema) throws -> Void) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let db = try #require(raw)
        defer { #expect(sqlite3_close(db) == SQLITE_OK) }
        try body(Schema(database: db, prepare: { sqlite3_prepare_v2($0, $1, -1, &$2, nil) }, step: sqlite3_step))
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test(arguments: ["UTF-8", "UTF-16le", "UTF-16be"])
    func acceptsPinnedVersionOneJournals(encoding: String) throws {
        try withDatabase { schema in
            let db = schema.database
            try execute(db, "PRAGMA encoding='\(encoding)'")
            try execute(db, "PRAGMA temp_store=MEMORY")
            try execute(db, "BEGIN")
            for ddl in MessageEventJournalFormat.createMain { try execute(db, ddl) }
            try schema.validateMain()
            try schema.requireEmptyTemp()
            try execute(db, "PRAGMA main.max_page_count=131072")
            try execute(db, "PRAGMA temp.max_page_count=4096")
            try execute(db, MessageEventJournalFormat.createStaging)
            #expect(throws: Schema.Failure.schemaMismatch) { try schema.requireEmptyTemp() }
            try schema.validateStaging()
            try execute(db, "PRAGMA temp.max_page_count=4097")
            #expect(throws: Schema.Failure.schemaMismatch) { try schema.validateStaging() }
        }
    }

    @Test(arguments: [-2049, -2048, -32, 0, 1, 512, 513, 100_000])
    func reducesOnlyOversizedCacheTargets(setting: Int) throws {
        try withDatabase { schema in
            let db = schema.database
            try execute(db, "BEGIN")
            for ddl in MessageEventJournalFormat.createMain { try execute(db, ddl) }
            try execute(db, "PRAGMA main.cache_size=\(setting)")
            try schema.validateMain()
            let expected = (-2048...512).contains(setting) ? setting : -2048
            try schema.withStatement("PRAGMA main.cache_size") { statement in
                #expect(sqlite3_step(statement) == SQLITE_ROW)
                #expect(sqlite3_column_int(statement, 0) == Int32(expected))
                #expect(sqlite3_step(statement) == SQLITE_DONE)
            }
        }
    }

    @Test func requiresATransactionAndDistinguishesEmptyCatalog() throws {
        try withDatabase { schema in
            #expect(throws: Schema.Failure.transactionRequired) { try schema.validateMain() }
            try execute(schema.database, "BEGIN")
            #expect(throws: Schema.Failure.uninitialized) { try schema.validateMain() }
            try execute(schema.database, "CREATE TABLE unrelated(id)")
            #expect(throws: Schema.Failure.schemaMismatch) { try schema.validateMain() }
        }
    }

    @Test(arguments: [
        "PRAGMA main.application_id=1", "PRAGMA main.user_version=2", "DROP INDEX baseline_locator",
        "DROP INDEX baseline_locator; CREATE INDEX baseline_locator ON baseline(message_rowid, chat_rowid)",
        "CREATE TRIGGER extra AFTER INSERT ON events BEGIN DELETE FROM events; END",
        "CREATE VIEW extraneous AS SELECT * FROM meta",
        "ALTER TABLE events ADD COLUMN extra AS (length(payload))"
    ])
    func rejectsAlteredCatalog(sql: String) throws {
        try withDatabase { schema in
            let db = schema.database
            try execute(db, "BEGIN")
            for ddl in MessageEventJournalFormat.createMain { try execute(db, ddl) }
            try execute(db, sql)
            #expect(throws: Schema.Failure.schemaMismatch) { try schema.validateMain() }
        }
    }

    @Test func preservesAuthorizationAndInterruptedScanFailures() throws {
        try withDatabase { schema in
            let db = schema.database
            try execute(db, "BEGIN")
            let denied = Schema(database: db, prepare: { _, _, _ in SQLITE_AUTH }, step: sqlite3_step)
            #expect(throws: Schema.Failure.sqliteCode(SQLITE_AUTH)) { try denied.validateMain() }
            let interrupted = Schema(database: db, prepare: schema.prepare, step: { _ in SQLITE_INTERRUPT })
            #expect(throws: Schema.Failure.sqliteCode(SQLITE_INTERRUPT)) { try interrupted.validateMain() }
            #expect(sqlite3_next_stmt(db, nil) == nil)
        }
    }
}
