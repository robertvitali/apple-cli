import SQLite3
import Testing
@testable import MessagesKit

struct MessageEventCatalogBudgetTests {
    private let scan = """
        WITH RECURSIVE n(x) AS (VALUES (1) UNION ALL SELECT x+1 FROM n WHERE x<2048)
        SELECT sum(x) FROM n
        """

    private func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let db = try #require(raw)
        defer { #expect(sqlite3_close(db) == SQLITE_OK) }
        try body(db)
    }

    @Test func refusalIsStickyAndRegularDataReadsRecoverTheirLimits() throws {
        try withDatabase { db in
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 524288)
            let originalColumns = sqlite3_limit(db, SQLITE_LIMIT_COLUMN, -1)
            #expect(throws: MessageEventCatalogBudget.Failure.workLimit) {
                try MessageEventCatalogBudget.run(on: db, until: .now.advanced(by: .seconds(5))) {
                    #expect(sqlite3_limit(db, SQLITE_LIMIT_COLUMN, -1) == 32)
                    #expect(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 4096)
                    #expect(sqlite3_exec(db, "SELECT zeroblob(65536)", nil, nil, nil) == SQLITE_TOOBIG)
                    #expect(sqlite3_exec(db, scan, nil, nil, nil) == SQLITE_INTERRUPT)
                    // Deliberately swallow SQLite's refusal. The scope must still throw.
                }
            }
            #expect(sqlite3_limit(db, SQLITE_LIMIT_COLUMN, -1) == originalColumns)
            #expect(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 524288)
            #expect(sqlite3_exec(db, scan, nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(db, "SELECT zeroblob(263174)", nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test func preservesStricterLimitsAndOperationErrors() throws {
        enum Marker: Error { case failure }
        try withDatabase { db in
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1024)
            sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 16)
            #expect(throws: Marker.failure) {
                try MessageEventCatalogBudget.run(on: db, until: .now.advanced(by: .seconds(5))) {
                    #expect(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 1024)
                    #expect(sqlite3_limit(db, SQLITE_LIMIT_COLUMN, -1) == 16)
                    throw Marker.failure
                }
            }
            #expect(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 1024)
            let result = try MessageEventCatalogBudget.run(on: db, until: .now.advanced(by: .seconds(5))) {
                sqlite3_exec(db, "SELECT 1", nil, nil, nil)
            }
            #expect(result == SQLITE_OK)
            #expect(throws: MessageEventCatalogBudget.Failure.deadline) {
                try MessageEventCatalogBudget.run(on: db, until: .now) { Issue.record("expired scope ran SQL") }
            }
        }
    }

    @Test func catalogRowsAreBoundedEvenWithFewVMInstructions() throws {
        try withDatabase { db in
            let six = "VALUES (1),(2),(3),(4),(5),(6)"
            let seven = six + ",(7)"
            // Separate statements may reuse SQLite's statement pointer after finalization.
            try MessageEventCatalogBudget.run(on: db, until: .now.advanced(by: .seconds(5))) {
                for _ in 0..<10 { #expect(sqlite3_exec(db, six, nil, nil, nil) == SQLITE_OK) }
            }
            #expect(throws: MessageEventCatalogBudget.Failure.workLimit) {
                try MessageEventCatalogBudget.run(on: db, until: .now.advanced(by: .seconds(5))) {
                    _ = sqlite3_exec(db, seven, nil, nil, nil)
                }
            }
            #expect(throws: MessageEventCatalogBudget.Failure.workLimit) {
                try MessageEventCatalogBudget.run(on: db, until: .now.advanced(by: .seconds(5))) {
                    for _ in 0..<11 { _ = sqlite3_exec(db, six, nil, nil, nil) }
                }
            }
            #expect(sqlite3_exec(db, seven, nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test func nestedStatementsHaveIndependentRowCounts() throws {
        try withDatabase { db in
            #expect(throws: MessageEventCatalogBudget.Failure.workLimit) {
                try MessageEventCatalogBudget.run(on: db, until: .now.advanced(by: .seconds(5))) {
                    var outer: OpaquePointer?
                    try #require(sqlite3_prepare_v2(db, "VALUES (1),(2),(3),(4),(5),(6),(7)", -1, &outer, nil) == SQLITE_OK)
                    defer { sqlite3_finalize(outer) }
                    for _ in 0..<6 {
                        try #require(sqlite3_step(outer) == SQLITE_ROW)
                        try #require(sqlite3_exec(db, "SELECT 1", nil, nil, nil) == SQLITE_OK)
                    }
                    _ = sqlite3_step(outer)
                }
            }
        }
    }

}
