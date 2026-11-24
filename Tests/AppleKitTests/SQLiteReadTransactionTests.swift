import Foundation
import SQLite3
import Testing
import TestSupport
@testable import AppleKit

@Suite("Bounded SQLite read transactions")
struct SQLiteReadTransactionTests {
    private let scratch = ScratchDirs("bounded-read")
    private let generous = SQLiteReadTransaction.Limits(
        timeout: 5, rows: 1_000, bytes: 1_048_576, valueBytes: 65_536)
    private typealias Failure = SQLiteReadTransaction.Failure

    private func database(wal: Bool = true) throws -> (URL, OpaquePointer) {
        let url = try scratch.directory().appendingPathComponent("synthetic.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        if wal { try #require(sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK) }
        try #require(sqlite3_exec(handle, "CREATE TABLE sample(value INTEGER); INSERT INTO sample VALUES(1),(2)",
                                  nil, nil, nil) == SQLITE_OK)
        return (url, handle)
    }

    @Test(arguments: [512, 4096, 65_536])
    func pageCacheTargetUsesTheSourcePageSizeAndPreservesSmallerSettings(pageSize: Int) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let db = try #require(raw)
        defer { #expect(sqlite3_close(db) == SQLITE_OK) }
        func execute(_ sql: String) throws { try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        func currentSetting() throws -> Int {
            var row: OpaquePointer?
            defer { sqlite3_finalize(row) }
            try #require(sqlite3_prepare_v2(db, "PRAGMA main.cache_size", -1, &row, nil) == SQLITE_OK)
            try #require(sqlite3_step(row) == SQLITE_ROW)
            return Int(sqlite3_column_int64(row, 0))
        }
        try execute("PRAGMA main.page_size=\(pageSize)")
        try execute("CREATE TABLE sample(id)")
        for target: Int32 in [1, 512, 2048] {
            var budgets = generous
            budgets.pageCacheKiB = target
            let pages = Int(target) * 1024 / pageSize
            for setting in [0, pages, pages + 1, -Int(target), -Int(target) - 1] {
                try execute("PRAGMA main.cache_size=\(setting)")
                let scope = try SQLiteReadTransaction(limits: budgets, isCancelled: { false })
                try scope.run(on: db) { _ in }
                let expected = setting > pages || setting < -Int(target) ? -Int(target) : setting
                #expect(try currentSetting() == expected)
            }
        }
        try execute("PRAGMA main.cache_size=100000")
        let ordinary = try SQLiteReadTransaction(limits: generous, isCancelled: { false })
        try ordinary.run(on: db) { _ in }
        #expect(try currentSetting() == 100000)
        var invalid = generous
        invalid.pageCacheKiB = 0
        #expect(throws: Failure.invalidLimits) { try SQLiteReadTransaction(limits: invalid, isCancelled: { false }) }
    }

    @Test func fullScanBudgetAccumulatesAcrossQueriesAndAllowsIndexedReads() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var limits = generous
        limits.fullScanSteps = 2
        var reads = 0
        #expect(throws: Failure.fullScanLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { db in
                for _ in 0..<2 {
                    try db.forEachRow("SELECT value FROM sample ORDER BY rowid") { _ in reads += 1 }
                }
                try db.forEachRow("SELECT value FROM sample WHERE rowid=1") { _ in reads += 1 }
                // No matching row; the final step still charges its full scan.
                try db.forEachRow("SELECT value FROM sample WHERE value=99") { _ in Issue.record("unexpected result") }
            }
        }
        #expect(reads == 5)
        limits.fullScanSteps = -1
        #expect(throws: Failure.invalidLimits) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in }
        }
    }

    @Test func snapshotSchemaLimitChecksTheLastPartialBatch() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var limits = generous
        limits.snapshotSchemaBytes = 1
        #expect(throws: Failure.snapshotSetupLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in
                Issue.record("oversized schema admitted")
            }
        }
        limits.snapshotSchemaBytes = 1 << 20
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { db in
            try db.forEachRow("SELECT value FROM sample") { _ in }
        }
        limits.snapshotSchemaBytes = 0
        #expect(throws: Failure.invalidLimits) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in }
        }
    }

    @Test func snapshotSchemaLimitInterruptsLoadingBeforeALaterWideTable() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        for index in 0..<64 {
            try #require(sqlite3_exec(writer, "CREATE VIEW view_\(index) AS SELECT 1", nil, nil, nil) == SQLITE_OK)
        }
        // The fixture writer allows the wide table. The bounded reader permits only 128 columns.
        let columns = (0..<129).map { "c" + String($0) }.joined(separator: ",")
        try #require(sqlite3_exec(writer, "CREATE TABLE wide(\(columns))", nil, nil, nil) == SQLITE_OK)
        #expect(throws: Failure.database(SQLITE_CORRUPT)) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { _ in
                Issue.record("wide table accepted")
            }
        }
        var limits = generous
        limits.snapshotSchemaBytes = 1
        #expect(throws: Failure.snapshotSetupLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in
                Issue.record("catalog passed the first footprint check")
            }
        }
    }

    @Test func setupCacheBudgetIsIndependentOfSchemaAndRowBudgets() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var limits = generous
        limits.snapshotCacheBytes = 1
        #expect(throws: Failure.snapshotSetupLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in
                Issue.record("caller ran after setup exceeded its cache budget")
            }
        }
        limits.snapshotCacheBytes = 0
        #expect(throws: Failure.invalidLimits) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in }
        }
        limits.snapshotCacheBytes = nil
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { db in
            var count = 0
            try db.forEachRow("SELECT value FROM sample") { _ in count += 1 }
            #expect(count == 2)
        }
    }

    @Test func snapshotSetupBudgetEndsBeforeCallerQueries() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var limits = generous
        // One ordinary schema object and one result from the snapshot pin.
        limits.snapshotSetupRows = 2
        var values: [Int64] = []
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { db in
            for _ in 0..<3 {
                try db.forEachRow("SELECT value FROM sample ORDER BY rowid") { row in
                    values.append(try #require(row.int("value")))
                }
            }
        }
        #expect(values == [1, 2, 1, 2, 1, 2])
        limits.snapshotSetupRows = 1
        #expect(throws: Failure.snapshotSetupLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in
                Issue.record("snapshot budget allowed caller queries")
            }
        }
        limits.snapshotSetupRows = 0
        #expect(throws: Failure.invalidLimits) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in }
        }
    }

    @Test("all queries see the pinned WAL snapshot while another connection commits")
    func coherentSnapshot() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var observed: [Int64] = []
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
            // The snapshot must be pinned before the body, not by its first query.
            #expect(sqlite3_exec(writer, "INSERT INTO sample VALUES(3)", nil, nil, nil) == SQLITE_OK)
            for _ in 0..<2 {
                try scope.forEachRow("SELECT count(*) AS n FROM sample") { observed.append($0.int("n")!) }
            }
        }
        #expect(observed == [2, 2])
        let fresh = try SQLiteReader(path: url.path, directOpen: .walAware)
        #expect(try fresh.rows("SELECT count(*) AS n FROM sample").first?.int("n") == 3)
    }

    @Test func metadataAndAggregatesShareOneBudget() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 2, bytes: 8192, valueBytes: 4096)
        #expect(throws: Failure.rowLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { scope in
                #expect(try scope.schemaRows(.columns, table: "sample").first?.text("name") == "value")
                let result = try scope.observationRows("SELECT min(value) AS lo, max(value) AS hi FROM sample", [])
                #expect(result.first?.int("lo") == 1)
                #expect(result.first?.int("hi") == 2)
                _ = try scope.schemaRows(.tableList, table: "sample")
            }
        }
    }

    @Test func observationPermissionsEndAtEachStatement() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let queries = [("SELECT max(value) FROM sample", SQLITE_ERROR), ("PRAGMA main.table_xinfo(sample)", SQLITE_AUTH)]
        for (sql, code) in queries {
            #expect(throws: Failure.database(code)) {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
                    _ = try scope.observationRows("SELECT max(value) FROM sample", [])
                    _ = try scope.schemaRows(.columns, table: "sample")
                    try scope.forEachRow(sql) { _ in }
                }
            }
        }
    }

    @Test("typed values preserve NUL text and empty blobs, and binds do not interpolate SQL")
    func typedValues() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let bound = "a\0b'; DROP TABLE sample; --"
        var observed: SQLiteReader.Row?
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
            try scope.forEachRow("SELECT ?1 AS t, X'' AS b, NULL AS n, 7 AS i, 1.5 AS r", [bound]) {
                observed = $0
            }
        }
        #expect(observed?.values == ["t": .text(bound), "b": .blob(Data()), "n": .null,
                                    "i": .integer(7), "r": .real(1.5)])
    }

    @Test(arguments: ["UTF-8", "UTF-16le", "UTF-16be"])
    func textBudgetsUseConvertedByteLength(_ encoding: String) throws {
        let url = try scratch.directory().appendingPathComponent("encoded.sqlite")
        var writer: OpaquePointer?
        try #require(sqlite3_open(url.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        let content = "\u{feff}" + String(repeating: "界", count: 200)
        try #require(sqlite3_exec(writer, """
            PRAGMA encoding='\(encoding)';
            CREATE TABLE sample(value TEXT);
            INSERT INTO sample VALUES(''),('\(content)');
            """, nil, nil, nil) == SQLITE_OK)
        for budget in [content.utf8.count - 1, content.utf8.count] {
            var values: [String] = []
            let result = Result {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: .init(
                    timeout: 5, rows: 2, bytes: budget, valueBytes: budget)) { scope in
                    try scope.forEachRow("SELECT value AS t, X'' AS b FROM sample ORDER BY rowid") { row in
                        #expect(row.values["b"] == .blob(Data()))
                        values.append(try #require(row.text("t")))
                    }
                }
            }
            if budget == content.utf8.count {
                try result.get()
                #expect(values == ["", content])
            } else {
                #expect(throws: Failure.valueLimit) { try result.get() }
                #expect(values == [""])
            }
        }
        let markers = ["", "\u{feff}", "\u{feff}A\0e\u{301}", "\u{feff}\u{feff}"]
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
            for marker in markers {
                var bytes: [UInt8]?
                try scope.forEachRow("SELECT ? AS marker", [marker]) { row in
                    bytes = Array(try #require(row.text("marker")).utf8)
                }
                #expect(bytes == Array(marker.utf8))
            }
        }
    }

    @Test("invalid UTF-8 is rejected rather than repaired")
    func invalidUTF8() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        #expect(throws: Failure.invalidText) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                try $0.forEachRow("SELECT CAST(X'FF' AS TEXT) AS t") { _ in Issue.record("Invalid row delivered") }
            }
        }
    }

    @Test("invalid limits fail before any file open", arguments: [
        SQLiteReadTransaction.Limits(timeout: 0, rows: 1, bytes: 1, valueBytes: 1),
        .init(timeout: .nan, rows: 1, bytes: 1, valueBytes: 1),
        .init(timeout: .infinity, rows: 1, bytes: 1, valueBytes: 1),
        .init(timeout: 61, rows: 1, bytes: 1, valueBytes: 1),
        .init(timeout: 1, rows: 0, bytes: 1, valueBytes: 1),
        .init(timeout: 1, rows: 1_000_001, bytes: 1, valueBytes: 1),
        .init(timeout: 1, rows: 1, bytes: 0, valueBytes: 1),
        .init(timeout: 1, rows: 1, bytes: 1_073_741_825, valueBytes: 1),
        .init(timeout: 1, rows: 1, bytes: 1, valueBytes: 2),
        .init(timeout: 1, rows: 1, bytes: 16_777_217, valueBytes: 16_777_217)
    ])
    func invalidLimits(_ limits: SQLiteReadTransaction.Limits) {
        #expect(throws: Failure.invalidLimits) {
            try SQLiteReader.withBoundedReadTransaction(path: "/nonexistent/synthetic.sqlite", limits: limits) { _ in
                Issue.record("Invalid limits reached transaction body")
            }
        }
    }

    @Test("missing database does not run an unpinned fallback")
    func missingDatabase() throws {
        let path = try scratch.directory().appendingPathComponent("missing.sqlite").path
        #expect(throws: Failure.couldNotOpen) {
            try SQLiteReader.withBoundedReadTransaction(path: path, limits: generous) { _ in
                Issue.record("Missing database reached transaction body")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("relative, URI and NUL-containing paths are rejected", arguments: [
        "relative.sqlite", "file:/synthetic.sqlite?mode=memory", "/synthetic.sqlite\0ignored"
    ])
    func invalidPaths(_ path: String) {
        #expect(throws: Failure.couldNotOpen) {
            try SQLiteReader.withBoundedReadTransaction(path: path, limits: generous) { _ in
                Issue.record("Invalid path reached transaction body")
            }
        }
    }

    @Test("corrupt source fails before invoking the capture body")
    func corruptSource() throws {
        let url = try scratch.directory().appendingPathComponent("corrupt.sqlite")
        try Data(repeating: 0x5A, count: 4_096).write(to: url)
        #expect(throws: Failure.self) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { _ in
                Issue.record("Corrupt source reached transaction body")
            }
        }
    }

    @Test("extra and excessive binds, SQL and labels are rejected before delivery")
    func inputBounds() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let cases: [(String, [String])] = [
            ("SELECT 1 AS n", ["extra"]),
            ("SELECT ?1 AS n", [String(repeating: "x", count: 65_537)]),
            ("SELECT ?1 AS n", Array(repeating: "x", count: 513)),
            ("SELECT ?1 AS n, ?2 AS m", Array(repeating: String(repeating: "x", count: 32_769), count: 2)),
            ("SELECT 1 AS n" + String(repeating: " ", count: 65_537), []),
            ("SELECT 1 AS \"" + String(repeating: "x", count: 1_025) + "\"", [])
        ]
        for (sql, binds) in cases {
            #expect(throws: Failure.self) {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                    try $0.forEachRow(sql, binds) { _ in Issue.record("Invalid input delivered a row") }
                }
            }
        }
    }

    @Test("large synthetic scan streams the complete result without collecting rows")
    func streamingScan() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 100_000, bytes: 800_000, valueBytes: 4_096)
        var count = 0
        var sum: Int64 = 0
        let escaped = try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { scope in
            try scope.forEachRow("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000) SELECT x FROM n") {
                count += 1
                sum += $0.int("x")!
            }
            return scope
        }
        #expect(count == 100_000)
        #expect(sum == 5_000_050_000)
        #expect(throws: Failure.inactive) { try escaped.forEachRow("SELECT 1 AS n") { _ in } }
    }

    @Test("write, attach, pragma and transaction statements are denied", arguments: [
        "INSERT INTO sample VALUES(3)", "DELETE FROM sample", "CREATE TEMP TABLE forbidden(x)",
        "ATTACH ':memory:' AS other", "PRAGMA user_version=42", "PRAGMA table_info(sample)",
        "COMMIT", "ROLLBACK", "SELECT load_extension('synthetic')"
    ])
    func deniesMutations(_ sql: String) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        #expect(throws: Failure.self) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                try $0.forEachRow(sql) { _ in Issue.record("Forbidden query delivered a row") }
            }
        }
        #expect(try SQLiteReader(path: url.path, directOpen: .walAware)
            .rows("SELECT count(*) AS n FROM sample").first?.int("n") == 2)
    }

    @Test func unlikelyHintIsLimitedToDirectQueriesWhenEnabled() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, "CREATE VIEW hinted AS SELECT unlikely(value=2) AS n FROM sample",
                                 nil, nil, nil) == SQLITE_OK)
        var limits = generous
        limits.allowsUnlikelyHint = true
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { db in
            var values: [SQLiteReader.Row.Value?] = []
            try db.forEachRow("SELECT unlikely(value=2) AS n FROM sample ORDER BY rowid") {
                values.append($0.values["n"])
            }
            #expect(values == [.integer(0), .integer(1)])
        }
        for sql in ["SELECT n FROM hinted", "SELECT likely(1)", "SELECT likelihood(1, 0.5)", "SELECT random()"] {
            #expect(throws: Failure.self) {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { db in
                    try db.forEachRow(sql) { _ in Issue.record("Unexpected row") }
                }
            }
        }
    }

    @Test("only documented SQL functions are authorized")
    func functionAllowlist() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var observed: SQLiteReader.Row?
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
            try $0.forEachRow("SELECT coalesce(NULL, 'ok') AS fallback, COUNT(*) AS n, length(zeroblob(3)) AS size, sum(value) AS total, typeof(value) AS kind FROM sample") {
                observed = $0
            }
        }
        #expect(observed?.values == ["fallback": .text("ok"), "n": .integer(2),
                                    "size": .integer(3), "total": .integer(3), "kind": .text("integer")])
        for sql in ["SELECT unlikely(1) AS n", "SELECT abs(-1) AS n", "SELECT randomblob(1) AS b", "SELECT sqlite_version() AS version",
                    "SELECT 'a' LIKE 'a' AS n", "SELECT 'a' GLOB 'a' AS n",
                    "SELECT '[1]' -> 0 AS n", "SELECT '[1]' ->> 0 AS n"] {
            #expect(throws: Failure.self) {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                    try $0.forEachRow(sql) { _ in Issue.record("Unlisted function delivered a row") }
                }
            }
        }
    }

    @Test("query shape and binds are strict", arguments: [
        "SELECT 1 AS n; SELECT 2 AS n", "SELECT 1 AS n\0; SELECT 2 AS n",
        "SELECT 1 AS n, 2 AS n", "", "SELECT ?1 AS n"
    ])
    func invalidQueries(_ sql: String) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        #expect(throws: Failure.self) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) {
                try $0.forEachRow(sql) { _ in Issue.record("Invalid query delivered a row") }
            }
        }
    }

    @Test("row limits are cumulative and cannot be swallowed into successful capture")
    func cumulativeRows() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 2, bytes: 65_536, valueBytes: 4_096)
        var count = 0
        #expect(throws: Failure.rowLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { scope in
                try scope.forEachRow("SELECT value FROM sample") { _ in count += 1 }
                try? scope.forEachRow("SELECT value FROM sample") { _ in count += 1 }
            }
        }
        #expect(count == 2)
    }

    @Test("selected byte limits are cumulative across separate queries")
    func cumulativeBytes() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 100, bytes: 1_024, valueBytes: 1_024)
        var count = 0
        #expect(throws: Failure.byteLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { scope in
                for _ in 0..<3 {
                    try scope.forEachRow("SELECT zeroblob(512) AS b") { _ in count += 1 }
                }
            }
        }
        #expect(count == 2)
    }

    @Test("oversized values fail before consumer delivery")
    func valueLimit() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 100, bytes: 65_536, valueBytes: 1_024)
        #expect(throws: Failure.valueLimit) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) {
                try $0.forEachRow("SELECT zeroblob(2048) AS b") { _ in Issue.record("Oversized value delivered") }
            }
        }
    }

    @Test("cancellation before opening and during row iteration")
    func cancellation() throws {
        #expect(throws: Failure.cancelled) {
            try SQLiteReader.withBoundedReadTransaction(path: "/nonexistent/synthetic.sqlite", limits: generous,
                                                       isCancelled: { true }) { _ in }
        }
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var cancelled = false
        var count = 0
        #expect(throws: Failure.cancelled) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous,
                                                       isCancelled: { cancelled }) {
                try $0.forEachRow("SELECT value FROM sample") { _ in count += 1; cancelled = true }
            }
        }
        #expect(count == 1)
    }

    @Test("exact value boundary and SQLite intermediate limits are independently enforced")
    func nativeValueBoundaries() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 10, bytes: 65_536, valueBytes: 1_024)
        var exactCount: Int?
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) {
            try $0.forEachRow("SELECT zeroblob(1024) AS b") { exactCount = $0.data("b")?.count }
        }
        #expect(exactCount == 1_024)
        for sql in ["SELECT zeroblob(1025) AS b", "SELECT length(zeroblob(1025)) AS n"] {
            #expect(throws: Failure.valueLimit) {
                try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) {
                    try $0.forEachRow(sql) { _ in Issue.record("Oversized value or intermediate delivered") }
                }
            }
        }
        // SQLite may read separate fields from a stored record larger than LENGTH.
        // The selected byte budget, not valueBytes, bounds their combined payload.
        try #require(sqlite3_exec(writer, "CREATE TABLE wide(a, b); INSERT INTO wide VALUES(zeroblob(600), zeroblob(600))",
                                  nil, nil, nil) == SQLITE_OK)
        var combined = 0
        try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) {
            try $0.forEachRow("SELECT a, b FROM wide") {
                combined = ($0.data("a")?.count ?? 0) + ($0.data("b")?.count ?? 0)
            }
        }
        #expect(combined == 1_200)
    }

    @Test("cancellation predicate cannot reenter at query entry or final checkpoint", arguments: [false, true])
    func cancellationPredicateReentrancy(atFinalCheckpoint: Bool) throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var saved: SQLiteReadTransaction?
        var armed = false
        var refusal: Failure?
        var delivered = 0
        #expect(throws: Failure.reentrant) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous, isCancelled: {
                if armed {
                    // One-shot entry makes a broken guard fail assertions, not overflow the stack.
                    armed = false
                    do { try saved?.forEachRow("SELECT 1 AS n") { _ in delivered += 1 } }
                    catch { refusal = error as? Failure }
                }
                return false
            }) { scope in
                saved = scope
                armed = true
                if !atFinalCheckpoint { try scope.forEachRow("SELECT value FROM sample") { _ in delivered += 1 } }
            }
        }
        #expect(refusal == .reentrant)
        #expect(delivered == 0)
    }

    @Test("progress callback interrupts expensive work before its first result")
    func progressDeadline() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        let limits = SQLiteReadTransaction.Limits(timeout: 0.05, rows: 10, bytes: 65_536, valueBytes: 4_096)
        let start = ContinuousClock.now
        #expect(throws: Failure.deadline) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) {
                try $0.forEachRow("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) AS total FROM n") { _ in
                    Issue.record("Expensive query unexpectedly completed")
                }
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("lock contention respects the same deadline and never calls body")
    func lockContention() throws {
        let (url, writer) = try database(wal: false)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil); sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let limits = SQLiteReadTransaction.Limits(timeout: 0.05, rows: 10, bytes: 65_536, valueBytes: 4_096)
        let start = ContinuousClock.now
        #expect(throws: Failure.deadline) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: limits) { _ in
                Issue.record("Locked source reached transaction body")
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("callback error releases the WAL snapshot and escaped scope cannot be reused")
    func cleanupAndEscaping() throws {
        struct CallbackError: Error {}
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        var escaped: SQLiteReadTransaction?
        #expect(throws: CallbackError.self) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
                escaped = scope
                try scope.forEachRow("SELECT value FROM sample") { _ in throw CallbackError() }
            }
        }
        let scope = try #require(escaped)
        #expect(throws: Failure.inactive) { try scope.forEachRow("SELECT 1 AS n") { _ in } }
        #expect(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK)
        #expect((try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))).isEmpty)
    }

    @Test("reentrant query fails the complete capture even if callback catches it")
    func reentrancy() throws {
        let (url, writer) = try database()
        defer { sqlite3_close(writer) }
        #expect(throws: Failure.reentrant) {
            try SQLiteReader.withBoundedReadTransaction(path: url.path, limits: generous) { scope in
                try scope.forEachRow("SELECT value FROM sample") { _ in
                    try? scope.forEachRow("SELECT 1 AS n") { _ in }
                }
            }
        }
    }
}
