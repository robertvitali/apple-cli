import Foundation
import SQLite3

/// A synchronous, closure-scoped read transaction. Not safe to share across threads.
/// Rows are delivered individually; limits count selected values, not total process memory.
public final class SQLiteReadTransaction {
    /// Budgets cover selected values, not SQLite VM or Swift allocation overhead.
    /// Rows and bytes accumulate across queries, including a partly decoded row that fails.
    /// Such a failure invalidates the whole capture; counters cannot be reused afterward.
    public struct Limits: Sendable {
        public let timeout: TimeInterval
        public let rows: Int
        public let bytes: Int
        public let valueBytes: Int

        /// Optional budget for SQLite row events while pinning the initial snapshot.
        /// Includes internal schema and planner-statistics reads, separately from caller queries.
        public var snapshotSetupRows: Int? = nil

        /// Optional limit on SQLite's reported schema heap during initial snapshot setup.
        /// Sampled during setup and at completion. It excludes other allocations.
        package var snapshotSchemaBytes: Int32? = nil

        /// Optional limit on SQLite-reported pager cache bytes while pinning the snapshot.
        /// Checked at each traced setup row and at completion.
        package var snapshotCacheBytes: Int32? = nil

        /// Optional connection-local main page-cache target for caller queries.
        /// SQLite treats this as a suggestion. Smaller inherited targets are preserved.
        package var pageCacheKiB: Int32? = nil

        /// Optional cumulative limit on SQLite-reported full scan steps in caller queries.
        /// Sampled during execution and before delivering a row. A final query may
        /// exceed the limit between progress callbacks, even if it returns no rows.
        public var fullScanSteps: Int32? = nil

        /// Permit SQLite’s unlikely() planner hint in direct queries on this snapshot.
        package var allowsUnlikelyHint = false

        /// Timeout must be finite and in (0, 60] seconds; rows in 1...1,000,000;
        /// bytes in 1...1,073,741,824; valueBytes in 1...16,777,216 and no larger than bytes.
        /// Integer and real values each cost 8 bytes, NULL costs 0, and TEXT/BLOB cost
        /// their payload length. A valueBytes budget below 8 therefore refuses numeric values.
        /// `valueBytes` also sets SQLite's length limit during expression evaluation and
        /// schema loading. Oversized schema text can fail before the capture body runs.
        /// It is not a cap on the combined size of separately projected column values.
        public init(timeout: TimeInterval, rows: Int, bytes: Int, valueBytes: Int) {
            self.timeout = timeout
            self.rows = rows
            self.bytes = bytes
            self.valueBytes = valueBytes
        }
    }

    /// Diagnostics intentionally omit SQL, file paths and selected values.
    public enum Failure: Error, Equatable {
        case invalidLimits, couldNotOpen, inactive, reentrant, cancelled, deadline
        case invalidQuery, invalidBindings, rowLimit, byteLimit, valueLimit, invalidText
        case snapshotSetupLimit, fullScanLimit
        case database(Int32)
    }

    private static let allowedFunctions: Set<String> = [
        "coalesce", "count", "length", "sum", "typeof", "zeroblob"
    ]

    package var allowsUnlikelyHint: Bool { limits.allowsUnlikelyHint }

    private let limits: Limits
    private let deadline: ContinuousClock.Instant
    private let isCancelled: () -> Bool
    private var handle: OpaquePointer?
    private var reading = false
    private var checkingCancellation = false
    private var rowCount = 0
    private var byteCount = 0
    private var remainingFullScanSteps: Int32?
    private var scanStatement: OpaquePointer?
    private var interruption: Failure?
    private var queryFailure: Error?
    private struct TableColumnAuthorization {
        let objectName: String
        var observed = false
    }
    private var tableColumnAuthorization: TableColumnAuthorization?

    package enum SchemaRead: String {
        case tableList = "table_list", columns = "table_xinfo", ordinaryColumns = "table_info", indexes = "index_list"
    }

    private var schemaRead: (kind: SchemaRead, table: String)?
    private var permitMinMax = false

    init(limits: Limits, isCancelled: @escaping () -> Bool) throws {
        guard limits.timeout.isFinite, limits.timeout > 0, limits.timeout <= 60,
              (1...1_000_000).contains(limits.rows),
              (1...1_073_741_824).contains(limits.bytes),
              (1...16_777_216).contains(limits.valueBytes),
              limits.valueBytes <= limits.bytes,
              limits.pageCacheKiB.map({ $0 > 0 }) ?? true,
              limits.snapshotCacheBytes.map({ $0 > 0 }) ?? true,
              limits.snapshotSchemaBytes.map({ $0 > 0 }) ?? true,
              limits.fullScanSteps.map({ (0...1_000_000_000).contains($0) }) ?? true,
              limits.snapshotSetupRows.map({ (1...1_000_000).contains($0) }) ?? true else { throw Failure.invalidLimits }
        self.limits = limits
        self.remainingFullScanSteps = limits.fullScanSteps
        self.isCancelled = isCancelled
        self.deadline = ContinuousClock.now.advanced(by: .seconds(limits.timeout))
    }

    func checkpoint() throws {
        if let queryFailure { throw queryFailure }
        if let interruption { throw interruption }
        checkingCancellation = true
        let cancelled = isCancelled()
        checkingCancellation = false
        // A predicate can call back into this scope and swallow its refusal.
        if let queryFailure { throw queryFailure }
        if cancelled { interruption = .cancelled; throw Failure.cancelled }
        if ContinuousClock.now >= deadline { interruption = .deadline; throw Failure.deadline }
    }

    private func shouldInterrupt() -> Bool {
        do {
            try checkpoint()
            try checkFullScanLimit()
            return false
        } catch { return true }
    }

    private func checkFullScanLimit() throws {
        guard let statement = scanStatement, let remaining = remainingFullScanSteps else { return }
        let steps = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0)
        guard steps >= 0, steps <= remaining else {
            interruption = .fullScanLimit
            throw Failure.fullScanLimit
        }
    }

    func run<T>(on db: OpaquePointer, _ body: (SQLiteReadTransaction) throws -> T) throws -> T {
        handle = db
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            return Unmanaged<SQLiteReadTransaction>.fromOpaque(context)
                .takeUnretainedValue().shouldInterrupt() ? 1 : 0
        }, context)
        sqlite3_busy_handler(db, { context, _ in
            guard let context else { return 0 }
            let scope = Unmanaged<SQLiteReadTransaction>.fromOpaque(context).takeUnretainedValue()
            guard !scope.shouldInterrupt() else { return 0 }
            sqlite3_sleep(1)
            return scope.shouldInterrupt() ? 0 : 1
        }, context)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(limits.valueBytes))
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 65_536)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 128)
        sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, 512)
        defer {
            handle = nil
            sqlite3_set_authorizer(db, nil, nil)
            sqlite3_progress_handler(db, 0, nil, nil)
            sqlite3_busy_handler(db, nil, nil)
            // Read-only rollback releases the snapshot even when cancellation is latched.
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
        try checkpoint()
        try executeInternal("BEGIN", on: db)
        // BEGIN is deferred. Reading the schema establishes the snapshot before body runs.
        try pinSnapshot(on: db)
        if let target = limits.pageCacheKiB { try reducePageCache(on: db, toKiB: target) }
        let rc = sqlite3_set_authorizer(db, { context, action, name, argument, schema, source in
            guard let context else { return SQLITE_DENY }
            let scope = Unmanaged<SQLiteReadTransaction>.fromOpaque(context).takeUnretainedValue()
            switch action {
            case SQLITE_SELECT, SQLITE_RECURSIVE: return SQLITE_OK
            case SQLITE_READ:
                if let name, sqlite3_stricmp(name, "pragma_table_xinfo") == 0,
                   scope.tableColumnAuthorization == nil { return SQLITE_DENY }
                return SQLITE_OK
            case SQLITE_PRAGMA:
                if let read = scope.schemaRead, let name, let argument, let schema,
                   String(cString: name) == read.kind.rawValue, String(cString: argument) == read.table,
                   String(cString: schema) == "main" { return SQLITE_OK }
                guard let permission = scope.tableColumnAuthorization,
                      let name, let argument, let schema,
                      String(cString: name) == "table_xinfo",
                      String(cString: argument) == permission.objectName,
                      String(cString: schema) == "main" else { return SQLITE_DENY }
                scope.tableColumnAuthorization?.observed = true
                return SQLITE_OK
            case SQLITE_FUNCTION:
                guard let argument else { return SQLITE_DENY }
                if scope.allowsUnlikelyHint && source == nil && sqlite3_stricmp(argument, "unlikely") == 0 {
                    return SQLITE_OK
                }
                let function = String(cString: argument).lowercased()
                if scope.permitMinMax && (function == "min" || function == "max") { return SQLITE_OK }
                return SQLiteReadTransaction.allowedFunctions.contains(function)
                    ? SQLITE_OK : SQLITE_DENY
            default: return SQLITE_DENY
            }
        }, context)
        guard rc == SQLITE_OK else { throw Failure.database(rc) }
        let result = try body(self)
        try checkpoint()
        return result
    }

    private func pinSnapshot(on db: OpaquePointer) throws {
        let sql = "SELECT rootpage FROM sqlite_schema LIMIT 1"
        guard limits.snapshotSetupRows != nil || limits.snapshotSchemaBytes != nil || limits.snapshotCacheBytes != nil else {
            return try executeInternal(sql, on: db)
        }
        let budget = SetupBudget(database: db, limits: limits)
        let context = Unmanaged.passUnretained(budget).toOpaque()
        let rc = sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_ROW), { _, context, _, _ in
            guard let context else { return 0 }
            Unmanaged<SetupBudget>.fromOpaque(context).takeUnretainedValue().observeRow()
            return 0
        }, context)
        guard rc == SQLITE_OK else { throw Failure.database(rc) }
        defer {
            sqlite3_trace_v2(db, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }
        // Interruption may arrive as the last row completes. Check the latch
        // even if SQLite returns success. Preserve cancellation and deadline errors.
        do { try executeInternal(sql, on: db) }
        catch Failure.database where budget.exceeded { throw Failure.snapshotSetupLimit }
        guard !budget.exceeded, budget.cacheFits(), budget.schemaFits() else { throw Failure.snapshotSetupLimit }
    }

    private final class SetupBudget {
        let database: OpaquePointer
        let rowLimit: Int?
        let schemaBytes: Int32?
        let cacheBytes: Int32?
        private var rows = 0
        private var interval = 32
        private var nextMeasurement = 32
        private var previousBytes: Int32?
        var exceeded = false

        init(database: OpaquePointer, limits: Limits) {
            self.database = database
            rowLimit = limits.snapshotSetupRows
            schemaBytes = limits.snapshotSchemaBytes
            cacheBytes = limits.snapshotCacheBytes
        }

        func observeRow() {
            guard !exceeded else { return }
            rows += 1
            if (rowLimit.map { rows > $0 } ?? false) || !cacheFits() || (rows == nextMeasurement && !schemaFits()) {
                exceeded = true
                sqlite3_interrupt(database)
            }
        }

        func cacheFits() -> Bool {
            guard let cacheBytes else { return true }
            var current: Int32 = 0, unused: Int32 = 0
            return sqlite3_db_status(database, SQLITE_DBSTATUS_CACHE_USED, &current, &unused, 0) == SQLITE_OK
                && current >= 0 && current <= cacheBytes
        }

        func schemaFits() -> Bool {
            guard let schemaBytes else { return true }
            var current: Int32 = 0, unused: Int32 = 0
            guard sqlite3_db_status(database, SQLITE_DBSTATUS_SCHEMA_USED, &current, &unused, 0) == SQLITE_OK,
                  current >= 0, current <= schemaBytes else { return false }
            // Asking SQLite to measure the schema walks its parsed objects. Back off while
            // the estimate is unchanged, as it commonly is while loading planner statistics.
            interval = previousBytes == current ? min(512, interval * 2) : 32
            previousBytes = current
            nextMeasurement = rows + interval
            return true
        }
    }

    private func reducePageCache(on db: OpaquePointer, toKiB target: Int32) throws {
        func readInteger(_ sql: String) throws -> Int64 {
            var row: OpaquePointer?
            defer { sqlite3_finalize(row) }
            try check(sqlite3_prepare_v2(db, sql, -1, &row, nil), expecting: SQLITE_OK)
            try check(sqlite3_step(row), expecting: SQLITE_ROW)
            guard sqlite3_column_type(row, 0) == SQLITE_INTEGER else { throw Failure.database(SQLITE_ERROR) }
            let value = sqlite3_column_int64(row, 0)
            try check(sqlite3_step(row), expecting: SQLITE_DONE)
            return value
        }
        let setting = try readInteger("PRAGMA main.cache_size")
        let kibibytes = Int64(target)
        if setting > 0 {
            // Positive settings count database pages. Negative settings count KiB.
            let pageSize = try readInteger("PRAGMA main.page_size")
            guard (512...65_536).contains(pageSize), pageSize.nonzeroBitCount == 1 else {
                throw Failure.database(SQLITE_ERROR)
            }
            if setting <= kibibytes * 1024 / pageSize { return }
        } else if setting >= -kibibytes {
            return
        }
        try executeInternal("PRAGMA main.cache_size=-\(target)", on: db)
        guard try readInteger("PRAGMA main.cache_size") == -kibibytes else { throw Failure.database(SQLITE_ERROR) }
    }

    private func executeInternal(_ sql: String, on db: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), expecting: SQLITE_OK)
        while true {
            try checkpoint()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            try check(result, expecting: SQLITE_ROW)
        }
        try checkpoint()
    }

    private func check(_ result: Int32, expecting expected: Int32) throws {
        try checkpoint()
        guard result == expected else {
            if result == SQLITE_TOOBIG { throw Failure.valueLimit }
            throw Failure.database(result)
        }
    }

    /// Call with fixed, trusted SQL and positional text parameters. The consumer must return promptly.
    /// By default only coalesce, count, length, sum, typeof and zeroblob are authorized.
    /// Event-source snapshots also permit the unlikely planner hint in direct queries.
    /// Function-backed operators such as LIKE, GLOB, -> and ->> are also refused.
    /// Every query or consumer error fails the complete capture, even when the caller catches it.
    public func forEachRow(
        _ sql: String, _ binds: [String] = [],
        _ consume: (SQLiteReader.Row) throws -> Void
    ) throws {
        try withReading { db in try readRows(sql, binds, on: db, consume) }
    }

    /// Fixed main-schema introspection shares the observation's row, value and time budgets.
    package func schemaRows(_ kind: SchemaRead, table: String) throws -> [SQLiteReader.Row] {
        var rows: [SQLiteReader.Row] = []
        try withReading { db in
            guard (1...128).contains(table.utf8.count),
                  table.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else { throw Failure.invalidQuery }
            schemaRead = (kind, table)
            defer { schemaRead = nil }
            try readRows("PRAGMA main.\(kind.rawValue)(\(table))", [], on: db) { rows.append($0) }
        }
        return rows
    }

    /// In addition to the standard read functions, observation queries may compute MIN and MAX.
    package func observationRows(_ sql: String, _ binds: [String]) throws -> [SQLiteReader.Row] {
        var rows: [SQLiteReader.Row] = []
        try withReading { db in
            permitMinMax = true
            defer { permitMinMax = false }
            try readRows(sql, binds, on: db) { rows.append($0) }
        }
        return rows
    }

    /// Read main-schema columns in schema order within this capture's pinned snapshot.
    /// Names must match [A-Za-z_][A-Za-z0-9_]{0,127}; SQLite lookup ignores ASCII case.
    /// Rows contain column_id, column_name, declared_type, not_null, primary_key_order
    /// and hidden_kind, preserving SQLite value types and including generated columns.
    /// Defaults are omitted. Views are supported; this does not prove an ordinary table.
    /// A missing object returns no rows; broken views and metadata failures throw.
    /// Metadata and any collision-check row share all cumulative read budgets.
    /// Every failure invalidates the capture; the consumer must return promptly.
    public func forEachTableColumn(
        _ objectName: String, _ consume: (SQLiteReader.Row) throws -> Void
    ) throws {
        try readTableColumns(objectName, statement: """
            SELECT cid AS column_id, name AS column_name, type AS declared_type,
                   "notnull" AS not_null, pk AS primary_key_order, hidden AS hidden_kind
            FROM pragma_table_xinfo(?, 'main') ORDER BY cid
            """, consume)
    }

    // Internal statement seam exercises missing-callback ROW/DONE paths in synthetic tests.
    // The public entry always supplies the fixed metadata query. No guard is bypassed here.
    func readTableColumns(
        _ objectName: String, statement: String, _ consume: (SQLiteReader.Row) throws -> Void
    ) throws {
        try withReading { db in
            let bytes = objectName.utf8
            let isLetter: (UInt8) -> Bool = { (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
            guard (1...128).contains(bytes.count), let first = bytes.first, isLetter(first),
                  bytes.dropFirst().allSatisfy({ isLetter($0) || (48...57).contains($0) }) else {
                throw Failure.invalidQuery
            }
            try readRows("SELECT 1 AS collision FROM main.sqlite_schema WHERE name = 'pragma_table_xinfo' COLLATE NOCASE LIMIT 1",
                         [], on: db) { _ in throw Failure.invalidQuery }
            tableColumnAuthorization = TableColumnAuthorization(objectName: objectName)
            defer { tableColumnAuthorization = nil }
            try readRows(statement, [objectName], on: db, consume)
        }
    }

    private func withReading(_ body: (OpaquePointer) throws -> Void) throws {
        do {
            guard let db = handle else { throw Failure.inactive }
            guard !reading, !checkingCancellation else { throw Failure.reentrant }
            reading = true
            defer { reading = false }
            try checkpoint()
            try body(db)
        }
        catch {
            queryFailure = error
            throw error
        }
    }

    private func readRows(
        _ sql: String, _ binds: [String], on db: OpaquePointer,
        _ consume: (SQLiteReader.Row) throws -> Void
    ) throws {
        guard !sql.utf8.contains(0), sql.utf8.count <= 65_536 else { throw Failure.invalidQuery }
        guard binds.count <= 512,
              binds.allSatisfy({ $0.utf8.count <= min(limits.valueBytes, 65_536) }),
              binds.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw Failure.invalidBindings
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try sql.withCString { source in
            var tail: UnsafePointer<CChar>?
            try check(sqlite3_prepare_v2(db, source, -1, &statement, &tail), expecting: SQLITE_OK)
            guard statement != nil, let tail,
                  String(cString: tail).utf8.allSatisfy({ [9, 10, 13, 32].contains($0) }),
                  sqlite3_stmt_readonly(statement) != 0 else { throw Failure.invalidQuery }
        }
        guard sqlite3_bind_parameter_count(statement) == binds.count else { throw Failure.invalidBindings }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, bind) in binds.enumerated() {
            try bind.withCString {
                try check(sqlite3_bind_text(statement, Int32(index + 1), $0,
                                            Int32(bind.utf8.count), transient), expecting: SQLITE_OK)
            }
        }
        let columns = sqlite3_column_count(statement)
        guard (1...128).contains(columns) else { throw Failure.invalidQuery }
        let names = try (0..<columns).map { column in
            guard let name = sqlite3_column_name(statement, column) else { throw Failure.database(SQLITE_NOMEM) }
            return String(cString: name)
        }
        guard names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }),
              Set(names).count == names.count else { throw Failure.invalidQuery }
        if remainingFullScanSteps != nil { scanStatement = statement }
        defer { scanStatement = nil }
        while true {
            try checkpoint()
            let result = sqlite3_step(statement)
            try checkpoint()
            try checkFullScanLimit()
            if result != SQLITE_DONE { try check(result, expecting: SQLITE_ROW) }
            if let permission = tableColumnAuthorization, !permission.observed {
                throw Failure.invalidQuery
            }
            if result == SQLITE_DONE {
                if let remaining = remainingFullScanSteps {
                    remainingFullScanSteps = remaining - sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0)
                }
                break
            }
            guard rowCount < limits.rows else { throw Failure.rowLimit }
            rowCount += 1
            var values: [String: SQLiteReader.Row.Value] = [:]
            for column in 0..<columns {
                try checkpoint()
                let type = sqlite3_column_type(statement, column)
                let count: Int
                switch type {
                case SQLITE_INTEGER, SQLITE_FLOAT: count = 8
                case SQLITE_TEXT, SQLITE_BLOB:
                    count = Int(sqlite3_column_bytes(statement, column))
                    // Converting UTF-16 to UTF-8 can fail here. Check immediately,
                    // before another accessor can retry or obscure the error.
                    if count == 0 && sqlite3_errcode(db) == SQLITE_NOMEM {
                        throw Failure.database(SQLITE_NOMEM)
                    }
                default: count = 0
                }
                guard count <= limits.valueBytes else { throw Failure.valueLimit }
                guard count <= limits.bytes - byteCount else { throw Failure.byteLimit }
                byteCount += count
                let name = names[Int(column)]
                switch type {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(statement, column) else {
                        throw Failure.database(SQLITE_NOMEM)
                    }
                    let bytes = UnsafeBufferPointer(start: pointer, count: count)
                    // Validate before decoding so malformed bytes cannot expand into replacement characters.
                    guard !transcode(bytes.makeIterator(), from: UTF8.self, to: UTF8.self,
                                     stoppingOnError: true, into: { _ in }) else { throw Failure.invalidText }
                    let text = String(decoding: bytes, as: UTF8.self)
                    values[name] = .text(text)
                case SQLITE_BLOB:
                    if count == 0 { values[name] = .blob(Data()) }
                    else if let pointer = sqlite3_column_blob(statement, column) {
                        values[name] = .blob(Data(bytes: pointer, count: count))
                    } else { throw Failure.database(SQLITE_NOMEM) }
                default: values[name] = .null
                }
            }
            try consume(SQLiteReader.Row(values: values))
            try checkpoint()
        }
    }
}
