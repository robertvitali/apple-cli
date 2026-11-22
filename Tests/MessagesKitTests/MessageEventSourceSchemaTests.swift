import AppleKit
import Foundation
import SQLite3
import TestSupport
import Testing
@testable import MessagesKit

struct MessageEventSourceSchemaTests {
    private typealias Schema = MessageEventSourceSchema
    private let scratch = ScratchDirs("event-source-schema")

    private func fixture(_ sql: String) throws -> String {
        let path = try scratch.directory().appendingPathComponent("source.sqlite").path
        var db: OpaquePointer?
        try #require(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return path
    }

    private func schema(_ path: String) throws -> Schema {
        try Schema.preflight(path: path, isCancelled: { false }) { db, schema in
            try schema.validatePartialPair(db, attachmentFields: ["guid"])
        }
    }

    @Test func v1IncludesNullSQLAndIsIndependentOfRootPages() throws {
        let table = "CREATE TABLE attachment(guid TEXT UNIQUE)"
        let original = try schema(fixture(table))
        #expect(original.digest.map { String(format: "%02x", $0) }.joined() ==
                "c34fd247e593cf20270ba8f91764722c4f3a8b78aa819b7c9e87627b0644c368")
        #expect(original.hasAttachment && !original.hasEdge)
        let a = try schema(fixture(table + ";CREATE TABLE companion(x)"))
        let b = try schema(fixture("CREATE TABLE companion(x);" + table))
        #expect(a.digest == b.digest && a.digest != original.digest)
        #expect(try schema(fixture(table + ";CREATE TABLE companion(X)")).digest != a.digest)
    }

    @Test func triggersAreFingerprintedButDoNotShadowPhysicalTables() throws {
        let base = "CREATE TABLE ATTACHMENT(guid);CREATE TABLE unrelated(x)"
        let trigger = ";CREATE TRIGGER attachment AFTER INSERT ON unrelated BEGIN SELECT 1; END"
        let original = try schema(fixture(base))
        let withTrigger = try schema(fixture(base + trigger))
        #expect(withTrigger.digest != original.digest && withTrigger.hasAttachment && !withTrigger.canReadAttachments)
        #expect(try !schema(fixture("CREATE TABLE unrelated(x)" + trigger)).hasAttachment)
    }

    @Test(arguments: ["CREATE VIEW attachment AS SELECT 1 AS guid",
                      "CREATE TABLE attachment(x,guid GENERATED ALWAYS AS(x))",
                      "CREATE TABLE message_attachment_join(message_id)"])
    func invalidPartialSourceFailsBeforeAllocation(ddl: String) throws {
        let path = try fixture(ddl)
        #expect(throws: Schema.Failure.invalidSourceSchema) { try schema(path) }
    }

    @Test func catalogBudgetChargesAllFramedBytes() throws {
        let text = String(repeating: "x", count: 31_000)
        let ddl = (0..<70).map { "CREATE VIEW v\($0) AS SELECT '\(text)'" }.joined(separator: ";")
        let path = try fixture(ddl)
        #expect(throws: Schema.Failure.schemaCapacity) { try schema(path) }
    }

    @Test func statisticsSetupIsChargedBeforeQualification() throws {
        let path = try fixture("""
            CREATE TABLE message(guid TEXT);
            CREATE INDEX message_guid ON message(guid);
            INSERT INTO message VALUES('fixture');
            ANALYZE;
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<9000)
            INSERT INTO sqlite_stat1 SELECT 'message','message_guid','1 1' FROM n;
            """)
        var qualified = false
        #expect(throws: Schema.Failure.schemaCapacity) {
            try Schema.preflight(path: path, isCancelled: { false }) { _, _ in qualified = true }
        }
        #expect(!qualified)
        // Other bounded readers keep their existing setup policy.
        let rows = try SQLiteReader.withBoundedReadTransaction(path: path, limits: .init(
            timeout: 5, rows: 1, bytes: 4096, valueBytes: 4096)) { db in
            var rows = 0
            try db.forEachRow("SELECT guid FROM message") { _ in rows += 1 }
            return rows
        }
        #expect(rows == 1)
    }

    @Test func sourceSetupHonorsSmallerCallerCacheBudget() throws {
        let path = try fixture("CREATE TABLE message(guid TEXT)")
        var limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 8192, bytes: 3 << 20, valueBytes: 1 << 20)
        limits.snapshotCacheBytes = 1
        #expect(throws: Schema.Failure.schemaCapacity) {
            try Schema.withSnapshot(path: path, limits: limits, isCancelled: { false }) { _ in
                Issue.record("source setup exceeded requested cache budget")
            }
        }
    }

    @Test func parsedSourceSchemaHonorsSmallerCallerBudget() throws {
        let path = try fixture("CREATE TABLE message(guid TEXT)")
        var limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 8192, bytes: 3 << 20, valueBytes: 1 << 20)
        limits.snapshotSchemaBytes = 1
        #expect(throws: Schema.Failure.schemaCapacity) {
            try Schema.withSnapshot(path: path, limits: limits, isCancelled: { false }) { _ in
                Issue.record("source schema exceeded requested footprint")
            }
        }
    }

    @Test func noMatchJoinCannotExhaustTheDeadlineBetweenRows() throws {
        let path = try fixture("""
            CREATE TABLE edge(value INTEGER);
            WITH RECURSIVE seq(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM seq WHERE i<2000)
            INSERT INTO edge SELECT i FROM seq;
            """)
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 1, bytes: 4096, valueBytes: 4096)
        #expect(throws: MessageEventCaptureLimit.sourceScanSteps) {
            try Schema.withSnapshot(path: path, limits: limits, isCancelled: { false }) { db in
                try db.forEachRow("SELECT a.value FROM edge a CROSS JOIN edge b NOT INDEXED WHERE a.value=-b.value") {
                    _ in Issue.record("unexpected match")
                }
            }
        }
    }

    @Test func capturePlanFailurePropagates() throws {
        enum PlanFailure: Error { case rejected }
        let path = try fixture("CREATE TABLE message(guid)")
        #expect(throws: PlanFailure.rejected) {
            try Schema.preflight(path: path, isCancelled: { false }) { _, _ in throw PlanFailure.rejected }
        }
    }
}
