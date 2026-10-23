import Foundation
import SQLite3
import Testing
import TestSupport
@testable import AppleKit

@Suite("Bounded same-snapshot column metadata")
struct SQLiteTableColumnTests {
    private let scratch = ScratchDirs("table-columns")
    private typealias Failure = SQLiteReadTransaction.Failure
    private let generous = SQLiteReadTransaction.Limits(
        timeout: 5, rows: 1_000, bytes: 1_048_576, valueBytes: 65_536)

    private func database() throws -> (URL, OpaquePointer) {
        let url = try scratch.directory().appendingPathComponent("synthetic.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        let writer = try #require(db)
        try #require(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(7)",
                                  nil, nil, nil) == SQLITE_OK)
        return (url, writer)
    }

    @Test("typed column metadata includes generated columns and omits defaults")
    func columnShape() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, "CREATE TABLE detail(id INTEGER PRIMARY KEY, value TEXT NOT NULL DEFAULT 'synthetic', generated TEXT GENERATED ALWAYS AS(value) VIRTUAL, stored TEXT GENERATED ALWAYS AS(value) STORED)",
                                  nil, nil, nil) == SQLITE_OK)
        var rows: [SQLiteReader.Row] = []
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
            try $0.forEachTableColumn("DETAIL") { rows.append($0) }
        }
        try #require(rows.count == 4)
        #expect(rows.map { $0.int("column_id") } == [0, 1, 2, 3])
        #expect(rows.map { $0.text("column_name") } == ["id", "value", "generated", "stored"])
        #expect(rows.map { $0.int("hidden_kind") } == [0, 0, 2, 3])
        #expect(rows[0].values == ["column_id": .integer(0), "column_name": .text("id"),
                                  "declared_type": .text("INTEGER"), "not_null": .integer(0),
                                  "primary_key_order": .integer(1), "hidden_kind": .integer(0)])
        #expect(rows[1].values == ["column_id": .integer(1), "column_name": .text("value"),
                                  "declared_type": .text("TEXT"), "not_null": .integer(1),
                                  "primary_key_order": .integer(0), "hidden_kind": .integer(0)])
        #expect(rows.allSatisfy { $0.values.count == 6 })
    }

    @Test("unknown objects, views and maximum-length identifiers retain their meanings")
    func supportedObjects() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let name = "_" + String(repeating: "x", count: 127)
        try #require(sqlite3_exec(writer, "CREATE VIEW sample_view AS SELECT value FROM sample; CREATE TABLE \(name)(untyped)",
                                  nil, nil, nil) == SQLITE_OK)
        var names: [String?] = []
        var untyped: SQLiteReader.Row?
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
            try scope.forEachTableColumn("missing") { _ in Issue.record("Missing object returned metadata") }
            try scope.forEachTableColumn("sample_view") { names.append($0.text("column_name")) }
            try scope.forEachTableColumn(name) { untyped = $0 }
            try scope.forEachRow("SELECT value FROM sample") { #expect($0.int("value") == 7) }
        }
        #expect(names == ["value"])
        #expect(untyped?.values["declared_type"] == .text(""))
    }

    @Test("invalid names fail and poison the capture", arguments: [
        "", "1sample", "main.sample", "sample'", "sample); DROP TABLE sample; --",
        "sample\0", "sámple", String(repeating: "x", count: 129)
    ])
    func invalidNames(_ name: String) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        #expect(throws: Failure.invalidQuery) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                try? $0.forEachTableColumn(name) { _ in Issue.record("Invalid name delivered a row") }
            }
        }
    }

    @Test("metadata stays pinned across a concurrent schema change")
    func schemaSnapshot() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var old: [String?] = []
        var fresh: [String?] = []
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
            try #require(sqlite3_exec(writer, "ALTER TABLE sample ADD COLUMN extra TEXT; INSERT INTO sample VALUES(8, 'new')",
                                      nil, nil, nil) == SQLITE_OK)
            try scope.forEachTableColumn("sample") { old.append($0.text("column_name")) }
            try scope.forEachRow("SELECT count(*) AS n FROM sample") { #expect($0.int("n") == 1) }
        }
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
            try scope.forEachTableColumn("sample") { fresh.append($0.text("column_name")) }
            try scope.forEachRow("SELECT count(*) AS n FROM sample") { #expect($0.int("n") == 2) }
        }
        #expect(old == ["value"])
        #expect(fresh == ["value", "extra"])
    }

    @Test("mixed-case table and view shadows are refused without delivering collision rows", arguments: [
        "CREATE TABLE PrAgMa_TaBlE_XiNfO(cid, name, type, notnull_value, pk, hidden)",
        "CREATE VIEW PRAGMA_TABLE_XINFO AS SELECT value AS cid FROM sample"
    ])
    func shadowing(_ sql: String) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
        #expect(throws: Failure.invalidQuery) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                try? $0.forEachTableColumn("sample") { _ in Issue.record("Shadow delivered a row") }
            }
        }
        #expect(throws: Failure.database(SQLITE_AUTH)) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                try? $0.forEachRow("SELECT cid FROM PRAGMA_TABLE_XINFO LIMIT 0") { _ in }
            }
        }
    }

    @Test("ordinary metadata reads are denied even when no scan runs", arguments: [false, true])
    func ordinaryDenial(afterMetadata: Bool) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        for sql in ["SELECT cid FROM pragma_table_xinfo('sample', 'main') LIMIT 0",
                    "SELECT cid FROM PRAGMA_TABLE_XINFO('sample', 'main') WHERE 0",
                    "PRAGMA main.table_xinfo(sample)"] {
            #expect(throws: Failure.database(SQLITE_AUTH)) {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
                    if afterMetadata { try scope.forEachTableColumn("sample") { _ in } }
                    try? scope.forEachRow(sql) { _ in Issue.record("Ordinary metadata row delivered") }
                }
            }
        }
    }

    @Test("missing authorization evidence fails on both ROW and DONE", arguments: [
        "SELECT ? AS probe", "SELECT ? AS probe WHERE 0"
    ])
    func missingObservation(_ sql: String) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var subsequentFailure: Failure?
        #expect(throws: Failure.invalidQuery) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
                try? scope.readTableColumns("sample", statement: sql) { _ in Issue.record("Unproven row delivered") }
                do { try scope.forEachRow("SELECT value FROM sample") { _ in Issue.record("Poisoned capture delivered") } }
                catch { subsequentFailure = error as? Failure }
            }
        }
        #expect(subsequentFailure == .invalidQuery)
    }

    @Test("broken view is an error rather than an absent object")
    func brokenView() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, "CREATE TABLE removed(x); CREATE VIEW broken AS SELECT x FROM removed; DROP TABLE removed",
                                  nil, nil, nil) == SQLITE_OK)
        #expect(throws: Failure.database(SQLITE_ERROR)) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                try? $0.forEachTableColumn("broken") { _ in Issue.record("Broken view delivered metadata") }
            }
        }
    }

    @Test("metadata shares cumulative row and byte budgets with data")
    func cumulativeBudgets() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        for (limits, failure) in [
            (SQLiteReadTransaction.Limits(timeout: 5, rows: 1, bytes: 65_536, valueBytes: 4_096), Failure.rowLimit),
            (.init(timeout: 5, rows: 10, bytes: 4_096, valueBytes: 4_096), Failure.byteLimit)
        ] {
            var count = 0
            #expect(throws: failure) {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { scope in
                    try scope.forEachTableColumn("sample") { _ in count += 1 }
                    try scope.forEachRow("SELECT zeroblob(4096) AS data") { _ in count += 1 }
                }
            }
            #expect(count == 1)
        }
    }

    @Test("oversized schema text refuses capture before its body runs")
    func schemaValueBound() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let longName = String(repeating: "x", count: 1_025)
        try #require(sqlite3_exec(writer, "CREATE TABLE oversized(\(longName) TEXT)", nil, nil, nil) == SQLITE_OK)
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 10, bytes: 65_536, valueBytes: 1_024)
        var entered = false
        #expect(throws: Failure.valueLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) {
                entered = true
                try $0.forEachTableColumn("oversized") { _ in Issue.record("Oversized metadata delivered") }
            }
        }
        #expect(!entered)
        // The schema itself is valid; an adequate length limit permits its metadata.
        var names: [String?] = []
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
            try $0.forEachTableColumn("oversized") { names.append($0.text("column_name")) }
        }
        #expect(names == [longName])
    }

    @Test("callback failure releases the snapshot and inactive beats invalid name")
    func callbackCleanup() throws {
        struct Stop: Error {}
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var saved: SQLiteReadTransaction?
        #expect(throws: Stop.self) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
                saved = scope
                try? scope.forEachTableColumn("sample") { _ in throw Stop() }
            }
        }
        let scope = try #require(saved)
        #expect(throws: Failure.inactive) { try scope.forEachTableColumn("") { _ in } }
        #expect(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK)
    }

    @Test("metadata and ordinary consumers cannot reenter either operation", arguments: [0, 1, 2])
    func reentry(_ direction: Int) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var refusal: Failure?
        #expect(throws: Failure.reentrant) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
                let consume: (SQLiteReader.Row) throws -> Void = { _ in
                    do {
                        if direction == 2 { try scope.forEachRow("SELECT value FROM sample") { _ in } }
                        else { try scope.forEachTableColumn("") { _ in } }
                    }
                    catch { refusal = error as? Failure }
                }
                if direction != 0 { try scope.forEachTableColumn("sample", consume) }
                else { try scope.forEachRow("SELECT value FROM sample", [], consume) }
            }
        }
        #expect(refusal == .reentrant)
    }

    @Test("cancellation callback cannot reenter metadata")
    func cancellationReentry() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var saved: SQLiteReadTransaction?
        var armed = false
        var refusal: Failure?
        #expect(throws: Failure.reentrant) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous, isCancelled: {
                if armed {
                    armed = false
                    do { try saved?.forEachTableColumn("") { _ in } }
                    catch { refusal = error as? Failure }
                }
                return false
            }) { scope in
                saved = scope
                armed = true
                try scope.forEachTableColumn("sample") { _ in Issue.record("Reentrant capture delivered") }
            }
        }
        #expect(refusal == .reentrant)
    }

    @Test("cancellation and deadline stop metadata capture")
    func interruptions() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var cancelled = false
        #expect(throws: Failure.cancelled) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous,
                                                       isCancelled: { cancelled }) {
                try $0.forEachTableColumn("sample") { _ in cancelled = true }
            }
        }
        let limits = SQLiteReadTransaction.Limits(timeout: 0.05, rows: 10, bytes: 65_536, valueBytes: 4_096)
        #expect(throws: Failure.deadline) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) {
                Thread.sleep(forTimeInterval: 0.06)
                try $0.forEachTableColumn("") { _ in Issue.record("Expired capture delivered") }
            }
        }
    }
}
